// The game's OpenXR client on Apple Vision Pro: see wwvr_xr.h. Objective-C++ with ARC, host side
// (malloc). The OpenXR calls follow TPVR's client (src/dusk/vr/vr_xr_bootstrap.hpp and
// vr_xr_submit.hpp: the Metal binding, IOSurface swapchains imported into Dawn, MTLSharedEvent
// fences both ways); the frame, panel and room logic is Wind Waker's own.

#include "wwvr_xr.h"

#include "sense_pad.h"
#include "wwvr_visionos.h"

#include <openxr/openxr.h>
#include "vr/visionos/xr_visionos.h"

#include <aurora/aurora.h>
#include <aurora/gfx.hpp>
#include <webgpu/webgpu_cpp.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <TargetConditionals.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

#define XR_LOG(...) std::fprintf(stderr, "[WWVR] xr: " __VA_ARGS__)

extern "C" bool wwvr_visionos_consume_world_recenter(void);  // game_host.mm
extern "C" bool wwvr_visionos_quit_requested(void);         // game_host.mm
extern "C" void wwvr_visionos_set_session_hold(bool held);  // game_host.mm

namespace {

constexpr int64_t kSrgbBgra = MTLPixelFormatBGRA8Unorm_sRGB;
// The panel: 4:3 like the game's screen, sharp enough for its text at a metre and a half.
constexpr uint32_t kPanelWidth = 1440;
constexpr uint32_t kPanelHeight = 1080;

// One OpenXR swapchain, its images imported into Dawn on first use.
struct Chain {
    XrSwapchain handle = XR_NULL_HANDLE;
    uint32_t width = 0, height = 0;
    std::vector<XrSwapchainImageMetalMKW> images;
    std::vector<wgpu::SharedTextureMemory> memory;
    std::vector<wgpu::Texture> textures;
    // This frame: the image acquired (game thread), the compositor's read fence it must wait on.
    int acquired = -1;
    void* acquireEvent = nullptr;
    uint64_t acquireValue = 0;
    // Render worker: Dawn's access to the acquired image is open; after the submit, the fence its
    // writes complete at (read back on the game thread after synchronize()).
    bool accessOpen = false;
    void* writeEvent = nullptr;
    uint64_t writeValue = 0;
    // The pending copy's source (set on the game thread before its task is pushed).
    wgpu::Texture source;
    wgpu::Texture sourceWhite;
    bool everReleased = false;
};

struct Actions {
    XrActionSet set = XR_NULL_HANDLE;
    XrAction grip = XR_NULL_HANDLE, aim = XR_NULL_HANDLE;
    XrAction trigger = XR_NULL_HANDLE, squeeze = XR_NULL_HANDLE, stick = XR_NULL_HANDLE;
    XrAction primary = XR_NULL_HANDLE, secondary = XR_NULL_HANDLE, menu = XR_NULL_HANDLE, stickClick = XR_NULL_HANDLE;
    XrAction haptic = XR_NULL_HANDLE;
    XrPath hand[2] = {XR_NULL_PATH, XR_NULL_PATH};
    XrSpace gripSpace[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
    XrSpace aimSpace[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
};

struct State {
    bool failed = false;  // the session can't be made: don't try again every frame
    XrInstance instance = XR_NULL_HANDLE;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    XrSession session = XR_NULL_HANDLE;
    XrSpace local = XR_NULL_HANDLE, view = XR_NULL_HANDLE;
    XrSessionState state = XR_SESSION_STATE_UNKNOWN;
    bool running = false;
    bool everRan = false;  // a frame was begun in this session (a stop after it holds the game)
    uint32_t eyeWidth = 0, eyeHeight = 0;
    Chain eye[2];
    Chain panel;
    Actions actions;
    // This frame.
    bool frameBegun = false;
    XrFrameState frameState{XR_TYPE_FRAME_STATE};
    XrView views[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
    XrView shownViews[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};  // what the eye images were drawn with
    bool eyeSubmitted[2] = {false, false};
    bool panelSubmitted = false;
    bool panelShown = false;
    uint64_t frames = 0;
    // The panel's place.
    int panelMode = 0;
    int placedMode = -1;
    float panelYaw = 0;
    XrVector3f panelCenter{0, 0, 0};
    XrPosef panelPose{{0, 0, 0, 1}, {0, 0, -1.5f}};
    float panelWidth = 1.4f;
    // The room.
    bool seeThrough = false;
    float opacity = 1;
    // Timing, for the log.
    double statsSince = 0;
    uint64_t statsFrames = 0;
    double waitMs = 0, syncMs = 0;
};

State g;
std::atomic_bool g_focusedOnce{false};

double Now() {
    return [NSProcessInfo processInfo].systemUptime;
}
std::atomic_bool g_running{false};

// Dawn objects the encoder tasks use (render worker).
struct Gpu {
    bool failed = false;
    wgpu::BindGroupLayout layout;
    wgpu::RenderPipeline copy, matte;
    std::vector<std::pair<void*, wgpu::SharedFence>> fences;  // the compositor's read events
};
Gpu gpu;
aurora::gfx::EncoderTaskId g_copyTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_finishTask = aurora::gfx::InvalidEncoderTask;

constexpr const char* kShader = R"(
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var white: texture_2d<f32>;

@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment fn fs_copy(@builtin(position) at: vec4f) -> @location(0) vec4f {
    return vec4f(textureLoad(source, vec2i(at.xy), 0).rgb, 1.0);
}

// The 2D drawn over black (b = a * c) and over white (w = a * c + 1 - a): a = 1 - (w - b), and b is
// the premultiplied colour, whatever blending the game used.
@fragment fn fs_matte(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let b = textureLoad(source, vec2i(at.xy), 0).rgb;
    let w = textureLoad(white, vec2i(at.xy), 0).rgb;
    let a = clamp(1.0 - dot(w - b, vec3f(1.0 / 3.0)), 0.0, 1.0);
    return vec4f(min(b, vec3f(a)), a);
}
)";

enum TaskTarget : uint32_t { kTargetEye0 = 0, kTargetEye1 = 1, kTargetPanel = 2 };
struct TaskPayload {
    uint32_t target;
};

Chain& ChainOf(uint32_t target) {
    return target == kTargetPanel ? g.panel : g.eye[target];
}

bool Check(XrResult result, const char* what) {
    if (XR_FAILED(result)) {
        const char* provider = xr_visionos_last_error();
        XR_LOG("%s failed: %d%s%s\n", what, static_cast<int>(result), provider != nullptr ? " " : "",
               provider != nullptr ? provider : "");
        return false;
    }
    return true;
}

// --- Dawn (render worker) ---

bool EnsureGpu(const wgpu::Device& device) {
    if (gpu.copy || gpu.failed) {
        return !gpu.failed;
    }
    wgpu::ShaderSourceWGSL wgsl{};
    wgsl.code = kShader;
    wgpu::ShaderModuleDescriptor moduleDesc{};
    moduleDesc.nextInChain = &wgsl;
    moduleDesc.label = "WWVR xr copy";
    wgpu::ShaderModule module = device.CreateShaderModule(&moduleDesc);
    std::array<wgpu::BindGroupLayoutEntry, 2> entries{};
    for (uint32_t i = 0; i < 2; ++i) {
        entries[i].binding = i;
        entries[i].visibility = wgpu::ShaderStage::Fragment;
        entries[i].texture.sampleType = wgpu::TextureSampleType::UnfilterableFloat;
        entries[i].texture.viewDimension = wgpu::TextureViewDimension::e2D;
    }
    wgpu::BindGroupLayoutDescriptor layoutDesc{};
    layoutDesc.entryCount = entries.size();
    layoutDesc.entries = entries.data();
    gpu.layout = device.CreateBindGroupLayout(&layoutDesc);
    wgpu::PipelineLayoutDescriptor pipelineLayoutDesc{};
    pipelineLayoutDesc.bindGroupLayoutCount = 1;
    pipelineLayoutDesc.bindGroupLayouts = &gpu.layout;
    wgpu::PipelineLayout layout = device.CreatePipelineLayout(&pipelineLayoutDesc);
    const auto make = [&](const char* entry) {
        wgpu::ColorTargetState target{};
        target.format = wgpu::TextureFormat::BGRA8Unorm;  // the IOSurfaces' own ('BGRA')
        wgpu::FragmentState fs{};
        fs.module = module;
        fs.entryPoint = entry;
        fs.targetCount = 1;
        fs.targets = &target;
        wgpu::RenderPipelineDescriptor desc{};
        desc.label = "WWVR xr copy";
        desc.layout = layout;
        desc.vertex.module = module;
        desc.vertex.entryPoint = "vs";
        desc.primitive.topology = wgpu::PrimitiveTopology::TriangleList;
        desc.fragment = &fs;
        return device.CreateRenderPipeline(&desc);
    };
    gpu.copy = make("fs_copy");
    gpu.matte = make("fs_matte");
    gpu.failed = !gpu.copy || !gpu.matte;
    if (gpu.failed) {
        XR_LOG("the copy pipelines failed\n");
    }
    return !gpu.failed;
}

wgpu::SharedFence ImportFence(const wgpu::Device& device, void* event) {
    if (event == nullptr) {
        return nullptr;
    }
    for (const auto& [known, fence] : gpu.fences) {
        if (known == event) {
            return fence;
        }
    }
    wgpu::SharedFenceMTLSharedEventDescriptor eventDesc{};
    eventDesc.sharedEvent = event;
    wgpu::SharedFenceDescriptor fenceDesc{};
    fenceDesc.nextInChain = &eventDesc;
    fenceDesc.label = "WWVR compositor read fence";
    wgpu::SharedFence fence = device.ImportSharedFence(&fenceDesc);
    gpu.fences.emplace_back(event, fence);
    return fence;
}

// The chain's acquired image as a Dawn texture with the access open (render worker).
wgpu::Texture OpenImage(const wgpu::Device& device, Chain& chain) {
    if (chain.acquired < 0) {
        return nullptr;
    }
    const size_t index = static_cast<size_t>(chain.acquired);
    if (chain.textures.size() < chain.images.size()) {
        chain.textures.resize(chain.images.size());
        chain.memory.resize(chain.images.size());
    }
    if (!chain.textures[index]) {
        wgpu::SharedTextureMemoryIOSurfaceDescriptor ioDesc{};
        ioDesc.ioSurface = chain.images[index].ioSurface;
        wgpu::SharedTextureMemoryDescriptor memoryDesc{};
        memoryDesc.nextInChain = &ioDesc;
        memoryDesc.label = "WWVR swapchain image";
        chain.memory[index] = device.ImportSharedTextureMemory(&memoryDesc);
        if (chain.memory[index]) {
            wgpu::SharedTextureMemoryProperties props{};
            chain.memory[index].GetProperties(&props);
            wgpu::TextureDescriptor textureDesc{};
            textureDesc.label = "WWVR swapchain image";
            textureDesc.usage = wgpu::TextureUsage::RenderAttachment;
            textureDesc.size = {chain.width, chain.height, 1};
            textureDesc.format = props.format;
            chain.textures[index] = chain.memory[index].CreateTexture(&textureDesc);
        }
        if (!chain.textures[index]) {
            XR_LOG("Dawn could not import a %ux%u swapchain image\n", chain.width, chain.height);
            return nullptr;
        }
    }
    if (!chain.accessOpen) {
        const wgpu::SharedFence fence = ImportFence(device, chain.acquireEvent);
        wgpu::SharedTextureMemoryBeginAccessDescriptor begin{};
        begin.initialized = false;  // every pixel is written
        if (fence) {
            begin.fenceCount = 1;
            begin.fences = &fence;
            begin.signaledValueCount = 1;
            begin.signaledValues = &chain.acquireValue;
        }
        if (chain.memory[index].BeginAccess(chain.textures[index], &begin) != wgpu::Status::Success) {
            XR_LOG("BeginAccess failed\n");
            return nullptr;
        }
        chain.accessOpen = true;
    }
    return chain.textures[index];
}

void CopyTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
              size_t, void*) {
    const uint32_t target = static_cast<const TaskPayload*>(payload)->target;
    Chain& chain = ChainOf(target);
    const bool panel = target == kTargetPanel;
    if (!EnsureGpu(ctx.device) || !chain.source || (panel && !chain.sourceWhite)) {
        return;
    }
    const wgpu::Texture image = OpenImage(ctx.device, chain);
    if (!image) {
        return;
    }
    std::array<wgpu::BindGroupEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].textureView = chain.source.CreateView();
    entries[1].binding = 1;
    entries[1].textureView = (panel ? chain.sourceWhite : chain.source).CreateView();
    wgpu::BindGroupDescriptor groupDesc{};
    groupDesc.layout = gpu.layout;
    groupDesc.entryCount = entries.size();
    groupDesc.entries = entries.data();
    wgpu::BindGroup group = ctx.device.CreateBindGroup(&groupDesc);
    wgpu::RenderPassColorAttachment colour{};
    colour.view = image.CreateView();
    colour.loadOp = wgpu::LoadOp::Clear;
    colour.storeOp = wgpu::StoreOp::Store;
    colour.clearValue = {0, 0, 0, panel ? 0.0 : 1.0};
    wgpu::RenderPassDescriptor passDesc{};
    passDesc.label = panel ? "WWVR panel" : "WWVR eye";
    passDesc.colorAttachmentCount = 1;
    passDesc.colorAttachments = &colour;
    wgpu::CommandEncoder encoder = cmd;
    wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&passDesc);
    pass.SetPipeline(panel ? gpu.matte : gpu.copy);
    pass.SetBindGroup(0, group);
    pass.SetViewport(0, 0, static_cast<float>(chain.width), static_cast<float>(chain.height), 0, 1);
    pass.Draw(3);
    pass.End();
    chain.source = nullptr;
    chain.sourceWhite = nullptr;
}

void FinishTask(const aurora::gfx::EncoderTaskContext&, const wgpu::CommandEncoder&, const void*, size_t, void*) {}

// After the frame's command buffer is submitted: Dawn's writes are in; keep the fences they signal.
void FinishSubmitted(const aurora::gfx::EncoderTaskCompletionContext&, const void*, size_t, void*) {
    for (Chain* chain : {&g.eye[0], &g.eye[1], &g.panel}) {
        if (!chain->accessOpen || chain->acquired < 0) {
            continue;
        }
        chain->accessOpen = false;
        const size_t index = static_cast<size_t>(chain->acquired);
        wgpu::SharedTextureMemoryEndAccessState end{};
        chain->memory[index].EndAccess(chain->textures[index], &end);
        for (size_t i = 0; i < end.fenceCount && i < end.signaledValueCount; ++i) {
            wgpu::SharedFenceMTLSharedEventExportInfo metal{};
            wgpu::SharedFenceExportInfo info{};
            info.nextInChain = &metal;
            end.fences[i].ExportInfo(&info);
            if (info.type == wgpu::SharedFenceType::MTLSharedEvent && metal.sharedEvent != nullptr) {
                chain->writeEvent = metal.sharedEvent;
                chain->writeValue = std::max(chain->writeValue, end.signaledValues[i]);
            }
        }
    }
}

void RegisterTasks() {
    if (g_copyTask != aurora::gfx::InvalidEncoderTask) {
        return;
    }
    aurora::gfx::EncoderTaskDescriptor copy{};
    copy.label = "WWVR xr copy";
    copy.callback = &CopyTask;
    g_copyTask = aurora::gfx::register_encoder_task_type(copy);
    aurora::gfx::EncoderTaskDescriptor finish{};
    finish.label = "WWVR xr finish";
    finish.callback = &FinishTask;
    finish.afterSubmit = &FinishSubmitted;
    g_finishTask = aurora::gfx::register_encoder_task_type(finish);
}

// --- OpenXR (game thread) ---

bool MakeChain(Chain& chain, uint32_t width, uint32_t height) {
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format = kSrgbBgra;
    info.sampleCount = 1;
    info.width = width;
    info.height = height;
    info.faceCount = 1;
    info.arraySize = 1;
    info.mipCount = 1;
    if (!Check(xrCreateSwapchain(g.session, &info, &chain.handle), "xrCreateSwapchain")) {
        return false;
    }
    uint32_t count = 0;
    xrEnumerateSwapchainImages(chain.handle, 0, &count, nullptr);
    chain.images.assign(count, XrSwapchainImageMetalMKW{XR_TYPE_SWAPCHAIN_IMAGE_METAL_MKW});
    if (!Check(xrEnumerateSwapchainImages(chain.handle, count, &count,
                                          reinterpret_cast<XrSwapchainImageBaseHeader*>(chain.images.data())),
               "xrEnumerateSwapchainImages")) {
        return false;
    }
    chain.width = width;
    chain.height = height;
    return true;
}

bool MakeActions() {
    Actions& a = g.actions;
    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    std::strncpy(setInfo.actionSetName, "wwvr", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(setInfo.localizedActionSetName, "Wind Waker VR", XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    if (!Check(xrCreateActionSet(g.instance, &setInfo, &a.set), "xrCreateActionSet")) {
        return false;
    }
    xrStringToPath(g.instance, "/user/hand/left", &a.hand[0]);
    xrStringToPath(g.instance, "/user/hand/right", &a.hand[1]);
    const auto action = [&](XrActionType type, const char* name, XrAction* out) {
        XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
        info.actionType = type;
        std::strncpy(info.actionName, name, XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(info.localizedActionName, name, XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        info.countSubactionPaths = 2;
        info.subactionPaths = a.hand;
        return Check(xrCreateAction(a.set, &info, out), name);
    };
    if (!action(XR_ACTION_TYPE_POSE_INPUT, "grip_pose", &a.grip) ||
        !action(XR_ACTION_TYPE_POSE_INPUT, "aim_pose", &a.aim) ||
        !action(XR_ACTION_TYPE_FLOAT_INPUT, "trigger", &a.trigger) ||
        !action(XR_ACTION_TYPE_FLOAT_INPUT, "squeeze", &a.squeeze) ||
        !action(XR_ACTION_TYPE_VECTOR2F_INPUT, "thumbstick", &a.stick) ||
        !action(XR_ACTION_TYPE_BOOLEAN_INPUT, "primary", &a.primary) ||
        !action(XR_ACTION_TYPE_BOOLEAN_INPUT, "secondary", &a.secondary) ||
        !action(XR_ACTION_TYPE_BOOLEAN_INPUT, "menu", &a.menu) ||
        !action(XR_ACTION_TYPE_BOOLEAN_INPUT, "stick_click", &a.stickClick) ||
        !action(XR_ACTION_TYPE_VIBRATION_OUTPUT, "haptic", &a.haptic)) {
        return false;
    }
    std::vector<XrActionSuggestedBinding> bindings;
    const auto bind = [&](XrAction act, const char* path) {
        XrPath p = XR_NULL_PATH;
        xrStringToPath(g.instance, path, &p);
        bindings.push_back({act, p});
    };
    for (const char* side : {"left", "right"}) {
        char path[128];
        const auto at = [&](const char* rest) {
            std::snprintf(path, sizeof(path), "/user/hand/%s/%s", side, rest);
            return path;
        };
        bind(a.grip, at("input/grip/pose"));
        bind(a.aim, at("input/aim/pose"));
        bind(a.trigger, at("input/trigger/value"));
        bind(a.squeeze, at("input/squeeze/value"));
        bind(a.stick, at("input/thumbstick"));
        bind(a.stickClick, at("input/thumbstick/click"));
        bind(a.haptic, at("output/haptic"));
        const bool left = side[0] == 'l';
        bind(a.primary, at(left ? "input/x/click" : "input/a/click"));
        bind(a.secondary, at(left ? "input/y/click" : "input/b/click"));
        if (left) {
            bind(a.menu, at("input/menu/click"));
        }
    }
    XrPath touch = XR_NULL_PATH;
    xrStringToPath(g.instance, "/interaction_profiles/oculus/touch_controller", &touch);
    XrInteractionProfileSuggestedBinding suggest{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    suggest.interactionProfile = touch;
    suggest.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
    suggest.suggestedBindings = bindings.data();
    if (!Check(xrSuggestInteractionProfileBindings(g.instance, &suggest), "xrSuggestInteractionProfileBindings")) {
        return false;
    }
    XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
    attach.countActionSets = 1;
    attach.actionSets = &a.set;
    if (!Check(xrAttachSessionActionSets(g.session, &attach), "xrAttachSessionActionSets")) {
        return false;
    }
    for (int hand = 0; hand < 2; ++hand) {
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};
        info.poseInActionSpace = {{0, 0, 0, 1}, {0, 0, 0}};
        info.subactionPath = a.hand[hand];
        info.action = a.grip;
        xrCreateActionSpace(g.session, &info, &a.gripSpace[hand]);
        info.action = a.aim;
        xrCreateActionSpace(g.session, &info, &a.aimSpace[hand]);
    }
    return true;
}

bool MakeSession() {
    if (g.session != XR_NULL_HANDLE) {
        return true;
    }
    if (g.failed) {
        return false;
    }
    g.failed = true;  // until it all works
    XrInstanceCreateInfo instanceInfo{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strncpy(instanceInfo.applicationInfo.applicationName, "Wind Waker VR", XR_MAX_APPLICATION_NAME_SIZE - 1);
    instanceInfo.applicationInfo.applicationVersion = 1;
    std::strncpy(instanceInfo.applicationInfo.engineName, "SwitchWaker", XR_MAX_ENGINE_NAME_SIZE - 1);
    instanceInfo.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    if (!Check(xrCreateInstance(&instanceInfo, &g.instance), "xrCreateInstance")) {
        return false;
    }
    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    if (!Check(xrGetSystem(g.instance, &systemInfo, &g.system), "xrGetSystem")) {
        return false;
    }
    std::array<XrViewConfigurationView, 2> viewConfig{{{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}}};
    uint32_t viewCount = 0;
    if (!Check(xrEnumerateViewConfigurationViews(g.instance, g.system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2,
                                                 &viewCount, viewConfig.data()),
               "xrEnumerateViewConfigurationViews")) {
        return false;
    }
    // The eye images at the compositor's size, times the render scale (the launcher's option; the
    // Simulator's single 4K view at half, or it crawls). The compositor scales them to the display.
    float scale = 1.0f;
#if TARGET_OS_SIMULATOR
    scale = 0.5f;
#endif
    if (const char* env = std::getenv("WWVR_RENDER_SCALE"); env != nullptr && std::atof(env) > 0.2) {
        scale = static_cast<float>(std::atof(env));
    } else if (NSInteger percent = [NSUserDefaults.standardUserDefaults integerForKey:@"vrRenderScale"];
               percent >= 50 && percent <= 150) {
        scale = percent / 100.0f;
    }
    g.eyeWidth = std::max<uint32_t>(256, static_cast<uint32_t>(viewConfig[0].recommendedImageRectWidth * scale) & ~7u);
    g.eyeHeight = std::max<uint32_t>(256, static_cast<uint32_t>(viewConfig[0].recommendedImageRectHeight * scale) & ~7u);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    XrGraphicsBindingMetalMKW binding{XR_TYPE_GRAPHICS_BINDING_METAL_MKW};
    binding.device = (__bridge void*)device;
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
    sessionInfo.next = &binding;
    sessionInfo.systemId = g.system;
    if (!Check(xrCreateSession(g.instance, &sessionInfo, &g.session), "xrCreateSession")) {
        return false;
    }
    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    spaceInfo.poseInReferenceSpace = {{0, 0, 0, 1}, {0, 0, 0}};
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    if (!Check(xrCreateReferenceSpace(g.session, &spaceInfo, &g.local), "xrCreateReferenceSpace(LOCAL)")) {
        return false;
    }
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    if (!Check(xrCreateReferenceSpace(g.session, &spaceInfo, &g.view), "xrCreateReferenceSpace(VIEW)")) {
        return false;
    }
    if (!MakeChain(g.eye[0], g.eyeWidth, g.eyeHeight) || !MakeChain(g.eye[1], g.eyeWidth, g.eyeHeight) ||
        !MakeChain(g.panel, kPanelWidth, kPanelHeight) || !MakeActions()) {
        return false;
    }
    RegisterTasks();
    // Nobody sees the offscreen SDL window's surface: the frames reach the headset.
    aurora::gfx::set_surface_present_suppressed(true);
    g.failed = false;
    XR_LOG("session made: eyes %ux%u, panel %ux%u\n", g.eyeWidth, g.eyeHeight, kPanelWidth, kPanelHeight);
    return true;
}

void PollEvents() {
    XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
    while (xrPollEvent(g.instance, &event) == XR_SUCCESS) {
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            const auto& changed = reinterpret_cast<const XrEventDataSessionStateChanged&>(event);
            g.state = changed.state;
            XR_LOG("session state %d\n", static_cast<int>(g.state));
            if (g.state == XR_SESSION_STATE_READY && !g.running) {
                XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};
                begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                g.running = Check(xrBeginSession(g.session, &begin), "xrBeginSession");
                g.placedMode = -1;  // place the panel again in the new space
            } else if (g.state == XR_SESSION_STATE_STOPPING && g.running) {
                xrEndSession(g.session);
                g.running = false;
            } else if (g.state == XR_SESSION_STATE_FOCUSED) {
                g_focusedOnce.store(true);
            }
        }
        event = XrEventDataBuffer{XR_TYPE_EVENT_DATA_BUFFER};
    }
    g_running.store(g.running);
}

wwvr_xr_pose ToPose(const XrPosef& p) {
    return {{p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w},
            {p.position.x, p.position.y, p.position.z}};
}

#if TARGET_OS_SIMULATOR
// Test runs: the Simulator tracks no hands or controllers. WWVR_TEST_HANDS=1 holds both where a
// player's would rest (a forearm's length ahead, below and either side of the head, pointing
// ahead and a little up); WWVR_TEST_SWING=<seconds>[,<seconds>...] sweeps the right hand across,
// fast, at those times since the session began.
void TestHands(wwvr_xr_input& in) {
    static const bool hands = std::getenv("WWVR_TEST_HANDS") != nullptr;
    if (!hands) {
        return;
    }
    static double start = Now();
    static std::vector<double> swings = [] {
        std::vector<double> times;
        if (const char* spec = std::getenv("WWVR_TEST_SWING")) {
            for (const char* p = spec; *p != 0;) {
                times.push_back(std::atof(p));
                const char* comma = std::strchr(p, ',');
                if (comma == nullptr) break;
                p = comma + 1;
            }
        }
        return times;
    }();
    const XrPosef& eye = g.views[0].pose;
    const XrQuaternionf& q = eye.orientation;
    // Rotate a head-space offset into LOCAL.
    const auto rotate = [&](float x, float y, float z) {
        const float tx = 2 * (q.y * z - q.z * y), ty = 2 * (q.z * x - q.x * z), tz = 2 * (q.x * y - q.y * x);
        return XrVector3f{x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz),
                          z + q.w * tz + (q.x * ty - q.y * tx)};
    };
    const double t = Now() - start;
    for (int hand = 0; hand < 2; ++hand) {
        float side = hand == 0 ? -0.2f : 0.2f;
        if (hand == 1) {
            for (double at : swings) {
                if (t >= at && t < at + 0.15) {
                    side = 0.35f - static_cast<float>((t - at) / 0.15) * 0.7f;  // 0.7 m in 0.15 s
                }
            }
        }
        const XrVector3f d = rotate(side, -0.3f, -0.35f);
        XrPosef pose;
        // Pitched up 15 degrees from the head's facing.
        const float s = std::sin(0.13f), c = std::cos(0.13f);
        pose.orientation = {q.w * s + q.x * c, q.y * c + q.z * s, q.z * c - q.y * s, q.w * c - q.x * s};
        pose.position = {eye.position.x + d.x, eye.position.y + d.y, eye.position.z + d.z};
        in.tracked[hand] = true;
        in.controller[hand] = true;
        in.grip[hand] = ToPose(pose);
        in.aim[hand] = ToPose(pose);
    }
}
#endif

void ReadInput(wwvr_xr_input& in) {
    in = {};
    const Actions& a = g.actions;
    XrActiveActionSet active{a.set, XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
    sync.countActiveActionSets = 1;
    sync.activeActionSets = &active;
    if (XR_FAILED(xrSyncActions(g.session, &sync))) {
        return;
    }
    const sense_pad::State sense = sense_pad::read();
    for (int hand = 0; hand < 2; ++hand) {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};
        get.subactionPath = a.hand[hand];
        XrActionStateFloat f{XR_TYPE_ACTION_STATE_FLOAT};
        get.action = a.trigger;
        if (XR_SUCCEEDED(xrGetActionStateFloat(g.session, &get, &f)) && f.isActive) in.trigger[hand] = f.currentState;
        get.action = a.squeeze;
        f = {XR_TYPE_ACTION_STATE_FLOAT};
        if (XR_SUCCEEDED(xrGetActionStateFloat(g.session, &get, &f)) && f.isActive) in.squeeze[hand] = f.currentState;
        XrActionStateVector2f v{XR_TYPE_ACTION_STATE_VECTOR2F};
        get.action = a.stick;
        if (XR_SUCCEEDED(xrGetActionStateVector2f(g.session, &get, &v)) && v.isActive) {
            in.stick_x[hand] = v.currentState.x;
            in.stick_y[hand] = v.currentState.y;
        }
        const auto boolean = [&](XrAction action) {
            XrActionStateBoolean b{XR_TYPE_ACTION_STATE_BOOLEAN};
            get.action = action;
            return XR_SUCCEEDED(xrGetActionStateBoolean(g.session, &get, &b)) && b.isActive && b.currentState;
        };
        in.primary[hand] = boolean(a.primary);
        in.secondary[hand] = boolean(a.secondary);
        in.stick_click[hand] = boolean(a.stickClick);
        if (hand == 0) {
            in.menu = boolean(a.menu);
        }
        XrSpaceLocation grip{XR_TYPE_SPACE_LOCATION};
        XrSpaceLocation aim{XR_TYPE_SPACE_LOCATION};
        const XrTime time = g.frameState.predictedDisplayTime;
        if (XR_SUCCEEDED(xrLocateSpace(a.gripSpace[hand], g.local, time, &grip)) &&
            XR_SUCCEEDED(xrLocateSpace(a.aimSpace[hand], g.local, time, &aim))) {
            const XrSpaceLocationFlags need = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
            in.tracked[hand] = (grip.locationFlags & need) == need;
            in.grip[hand] = ToPose(grip.pose);
            in.aim[hand] = ToPose(aim.pose);
        }
        in.controller[hand] = sense.connected;
    }
#if TARGET_OS_SIMULATOR
    TestHands(in);
#endif
}

// Yaw (radians, about +Y, 0 looking down -Z) of a pose's forward direction.
float YawOf(const XrQuaternionf& q) {
    // Forward = q * (0, 0, -1).
    const float fx = -2.f * (q.x * q.z + q.w * q.y);
    const float fz = -(1.f - 2.f * (q.x * q.x + q.y * q.y));
    return std::atan2(-fx, -fz);
}

// The panel follows the head lazily: it turns to the head's heading only when that's more than a
// comfortable angle away, and slides there, so reading and looking around the HUD stays put.
void PlacePanel(const XrPosef& head) {
    const bool menu = g.panelMode == 1;
    const float distance = menu ? 1.0f : 1.5f;
    g.panelWidth = menu ? 1.15f : 1.5f;
    const float drop = menu ? 0.05f : 0.12f;  // below eye level
    const float headYaw = YawOf(head.orientation);
    auto wrap = [](float a) {
        while (a > float(M_PI)) a -= 2 * float(M_PI);
        while (a < -float(M_PI)) a += 2 * float(M_PI);
        return a;
    };
    if (g.placedMode != g.panelMode) {
        g.placedMode = g.panelMode;
        g.panelYaw = headYaw;
        g.panelCenter = head.position;
    } else {
        const float off = wrap(headYaw - g.panelYaw);
        const float follow = menu ? 0.45f : 0.6f;  // radians before it starts to follow
        if (std::fabs(off) > follow) {
            g.panelYaw = wrap(g.panelYaw + (off - std::copysign(follow, off)) * 0.12f);
        }
        const float k = 0.05f;
        g.panelCenter.x += (head.position.x - g.panelCenter.x) * k;
        g.panelCenter.y += (head.position.y - g.panelCenter.y) * k;
        g.panelCenter.z += (head.position.z - g.panelCenter.z) * k;
    }
    // Facing the viewer; the HUD, below eye level, tipped back a little to face the eyes (a
    // negative turn about X points the quad's normal, +Z, up).
    const float tilt = menu ? 0.0f : -0.12f;
    const float s = std::sin(g.panelYaw * 0.5f), c = std::cos(g.panelYaw * 0.5f);
    const float ts = std::sin(tilt * 0.5f), tc = std::cos(tilt * 0.5f);
    // yaw (about Y) then pitch (about X): q = qy * qx
    g.panelPose.orientation = {c * ts, s * tc, -s * ts, c * tc};
    const float fx = -std::sin(g.panelYaw), fz = -std::cos(g.panelYaw);
    g.panelPose.position = {g.panelCenter.x + fx * distance, g.panelCenter.y - drop, g.panelCenter.z + fz * distance};
}

void ReleaseChain(Chain& chain) {
    if (chain.acquired < 0) {
        return;
    }
    xr_visionos_swapchain_image_set_release_fence(chain.handle, static_cast<uint32_t>(chain.acquired),
                                                  chain.writeEvent, chain.writeValue);
    XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(chain.handle, &release);
    chain.acquired = -1;
    chain.writeEvent = nullptr;
    chain.writeValue = 0;
    chain.everReleased = true;
}

bool Acquire(Chain& chain) {
    if (chain.acquired >= 0) {
        return true;
    }
    uint32_t index = 0;
    XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
    if (!Check(xrAcquireSwapchainImage(chain.handle, &acquire, &index), "xrAcquireSwapchainImage")) {
        return false;
    }
    XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
    wait.timeout = XR_INFINITE_DURATION;
    xrWaitSwapchainImage(chain.handle, &wait);
    chain.acquired = static_cast<int>(index);
    chain.acquireEvent = nullptr;
    chain.acquireValue = 0;
    xr_visionos_swapchain_image_acquire_fence(chain.handle, index, &chain.acquireEvent, &chain.acquireValue);
    return true;
}

}  // namespace

extern "C" {

bool wwvr_xr_wanted(void) {
    return xr_visionos_layer_renderer() != nullptr && !xr_visionos_layer_invalidated();
}

bool wwvr_xr_running(void) {
    return g_running.load();
}

bool wwvr_xr_focused_once(void) {
    return g_focusedOnce.load();
}

bool wwvr_xr_begin_frame(wwvr_xr_frame* frame) {
    if (frame == nullptr) {
        return false;
    }
    // Only a frame that renders updates the head, eyes and hands; others keep the last ones.
    frame->render = false;
    frame->recentered = false;
    if (g.session == XR_NULL_HANDLE && !wwvr_xr_wanted()) {
        return false;
    }
    if (!MakeSession()) {
        return false;
    }
    PollEvents();
    if (!g.running && g.everRan && !wwvr_visionos_quit_requested()) {
        // The Digital Crown closed the space (or the headset came off): the game holds right here,
        // its clock and sound stopped, until a new layer starts the session again (the launcher's
        // Resume) or the app quits.
        XR_LOG("holding the game until the space opens again\n");
        wwvr_visionos_set_session_hold(true);
        while (!g.running && !wwvr_visionos_quit_requested()) {
            usleep(50 * 1000);
            PollEvents();
        }
        wwvr_visionos_set_session_hold(false);
        XR_LOG("%s\n", g.running ? "the space is back: the game carries on" : "quitting");
    }
    if (!g.running) {
        return false;
    }
    g.everRan = true;
    const double waitStart = Now();
    g.frameState = {XR_TYPE_FRAME_STATE};
    XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
    if (!Check(xrWaitFrame(g.session, &waitInfo, &g.frameState), "xrWaitFrame")) {
        return false;
    }
    XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
    const XrResult begun = xrBeginFrame(g.session, &beginInfo);
    if (XR_FAILED(begun)) {
        Check(begun, "xrBeginFrame");
        return false;
    }
    g.frameBegun = true;
    g.waitMs += (Now() - waitStart) * 1000.0;
    g.eyeSubmitted[0] = g.eyeSubmitted[1] = false;
    g.panelSubmitted = false;
    ++g.frames;
    frame->frame = g.frames;
    frame->display_period_ns = g.frameState.predictedDisplayPeriod;
    if (!g.frameState.shouldRender) {
        return true;  // a frame to end, nothing to draw
    }
    XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
    locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locate.displayTime = g.frameState.predictedDisplayTime;
    locate.space = g.local;
    XrViewState viewState{XR_TYPE_VIEW_STATE};
    uint32_t count = 0;
    g.views[0] = {XR_TYPE_VIEW};
    g.views[1] = {XR_TYPE_VIEW};
    if (!Check(xrLocateViews(g.session, &locate, &viewState, 2, &count, g.views), "xrLocateViews") ||
        (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) == 0) {
        return true;
    }
    // The head: between the eyes, turned as they are (one device pose query fewer a frame; each is a
    // round trip to the pose service in the Simulator).
    XrSpaceLocation head{XR_TYPE_SPACE_LOCATION};
    head.pose.orientation = g.views[0].pose.orientation;
    head.pose.position = {(g.views[0].pose.position.x + g.views[1].pose.position.x) * 0.5f,
                          (g.views[0].pose.position.y + g.views[1].pose.position.y) * 0.5f,
                          (g.views[0].pose.position.z + g.views[1].pose.position.z) * 0.5f};
    frame->render = true;
    // A recentre is taken by the first frame that renders (the head is where it happened).
    frame->recentered = wwvr_visionos_consume_world_recenter();
    if (frame->recentered) {
        g.placedMode = -1;
    }
    frame->width = g.eyeWidth;
    frame->height = g.eyeHeight;
    frame->head = ToPose(head.pose);
    for (int i = 0; i < 2; ++i) {
        frame->eye[i] = ToPose(g.views[i].pose);
        frame->fov[i] = {g.views[i].fov.angleLeft, g.views[i].fov.angleRight, g.views[i].fov.angleUp,
                         g.views[i].fov.angleDown};
    }
    ReadInput(frame->input);
    PlacePanel(head.pose);
    return true;
}

void wwvr_xr_submit_eye(int eye, void* texture) {
    if (!g.frameBegun || eye < 0 || eye > 1 || texture == nullptr || !Acquire(g.eye[eye])) {
        return;
    }
    g.eye[eye].source = wgpu::Texture(static_cast<WGPUTexture>(texture));
    const TaskPayload payload{static_cast<uint32_t>(eye)};
    if (aurora::gfx::push_encoder_task(g_copyTask, &payload, sizeof(payload))) {
        g.eyeSubmitted[eye] = true;
        g.shownViews[eye] = g.views[eye];
    }
}

void wwvr_xr_submit_panel(void* over_black, void* over_white, uint32_t width, uint32_t height) {
    if (!g.frameBegun || over_black == nullptr || over_white == nullptr || width != kPanelWidth ||
        height != kPanelHeight || !Acquire(g.panel)) {
        return;
    }
    g.panel.source = wgpu::Texture(static_cast<WGPUTexture>(over_black));
    g.panel.sourceWhite = wgpu::Texture(static_cast<WGPUTexture>(over_white));
    const TaskPayload payload{kTargetPanel};
    g.panelSubmitted = aurora::gfx::push_encoder_task(g_copyTask, &payload, sizeof(payload));
}

void wwvr_xr_set_panel_mode(int mode) {
    g.panelMode = mode;
}

void wwvr_xr_finish_encoding(void) {
    if (!g.frameBegun) {
        return;
    }
    const TaskPayload payload{0};
    aurora::gfx::push_encoder_task(g_finishTask, &payload, sizeof(payload));
}

void wwvr_xr_end_frame(void) {
    if (!g.frameBegun) {
        return;
    }
    g.frameBegun = false;
    // The render worker has encoded and submitted this frame, and FinishSubmitted has the fences.
    const double syncStart = Now();
    aurora::gfx::synchronize();
    g.syncMs += (Now() - syncStart) * 1000.0;
    for (Chain* chain : {&g.eye[0], &g.eye[1], &g.panel}) {
        ReleaseChain(*chain);
    }
    xr_visionos_set_frame_environment(g.session, g.seeThrough);
    xr_visionos_set_frame_opacity(g.session, g.opacity);

    XrCompositionLayerProjectionView views[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},
                                              {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
    std::array<const XrCompositionLayerBaseHeader*, 2> layers{};
    uint32_t layerCount = 0;
    // The eyes drawn this frame; or, opaque, the last ones drawn (the compositor shows them where
    // they were). See-through with no eyes this frame (a menu over the room): no world at all.
    const bool eyesNow = g.eyeSubmitted[0] && g.eyeSubmitted[1];
    const bool eyesBefore = !g.seeThrough && g.eye[0].everReleased && g.eye[1].everReleased;
    if (g.frameState.shouldRender && (eyesNow || eyesBefore)) {
        for (int i = 0; i < 2; ++i) {
            views[i].pose = g.shownViews[i].pose;
            views[i].fov = g.shownViews[i].fov;
            views[i].subImage.swapchain = g.eye[i].handle;
            views[i].subImage.imageRect = {{0, 0}, {static_cast<int32_t>(g.eye[i].width), static_cast<int32_t>(g.eye[i].height)}};
        }
        projection.space = g.local;
        projection.viewCount = 2;
        projection.views = views;
        // Opaque: the eye images are (fs_copy writes alpha 1). See-through shows the room by leaving
        // this layer out (menus) and through its opacity (fades); a blended layer would ignore the
        // opacity and lose FXAA in the provider.
        projection.layerFlags = 0;
        layers[layerCount++] = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection);
    }
    if (g.panelSubmitted) {
        g.panelShown = true;
    }
    if (g.frameState.shouldRender && g.panelShown && g.panel.everReleased) {
        quad.space = g.local;
        quad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
        quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        quad.subImage.swapchain = g.panel.handle;
        quad.subImage.imageRect = {{0, 0}, {static_cast<int32_t>(kPanelWidth), static_cast<int32_t>(kPanelHeight)}};
        quad.pose = g.panelPose;
        quad.size = {g.panelWidth, g.panelWidth * kPanelHeight / kPanelWidth};
        layers[layerCount++] = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad);
    }
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
    end.displayTime = g.frameState.predictedDisplayTime;
    end.environmentBlendMode = g.seeThrough ? XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND : XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    end.layerCount = layerCount;
    end.layers = layers.data();
    Check(xrEndFrame(g.session, &end), "xrEndFrame");
    if (g.frames == 1 || g.frames % 900 == 0) {
        const double now = Now();
        const double span = g.statsSince > 0 ? now - g.statsSince : 0;
        const double n = static_cast<double>(g.frames - g.statsFrames);
        XR_LOG("frame %llu: %u layers, eyes %d%d (%ux%u), panel %d, see-through %d, opacity %.2f; %.1f frames/s, "
               "waiting %.1f ms and syncing %.1f ms a frame\n",
               static_cast<unsigned long long>(g.frames), layerCount, g.eyeSubmitted[0] ? 1 : 0,
               g.eyeSubmitted[1] ? 1 : 0, g.eyeWidth, g.eyeHeight, g.panelSubmitted ? 1 : 0, g.seeThrough ? 1 : 0,
               g.opacity, span > 0 ? n / span : 0.0, n > 0 ? g.waitMs / n : 0.0, n > 0 ? g.syncMs / n : 0.0);
        g.statsSince = now;
        g.statsFrames = g.frames;
        g.waitMs = g.syncMs = 0;
    }
}

void wwvr_xr_set_room(bool see_through, float opacity) {
    g.seeThrough = see_through;
    g.opacity = std::clamp(opacity, 0.0f, 1.0f);
}

void wwvr_xr_haptic(int hand, float amplitude, float seconds) {
    if (g.session == XR_NULL_HANDLE || !g.running || hand < 0 || hand > 1) {
        return;
    }
    XrHapticVibration vibration{XR_TYPE_HAPTIC_VIBRATION};
    vibration.amplitude = std::clamp(amplitude, 0.0f, 1.0f);
    vibration.duration = static_cast<XrDuration>(seconds * 1e9);
    vibration.frequency = XR_FREQUENCY_UNSPECIFIED;
    XrHapticActionInfo info{XR_TYPE_HAPTIC_ACTION_INFO};
    info.action = g.actions.haptic;
    info.subactionPath = g.actions.hand[hand];
    xrApplyHapticFeedback(g.session, &info, reinterpret_cast<const XrHapticBaseHeader*>(&vibration));
}

void wwvr_xr_panel_size(uint32_t* width, uint32_t* height) {
    if (width != nullptr) *width = kPanelWidth;
    if (height != nullptr) *height = kPanelHeight;
}

void wwvr_xr_get_comfort(wwvr_xr_comfort* comfort) {
    // The launcher's Advanced options (PortContent.swift's ComfortOptions), as TPVR's defaults:
    // smooth turning at 135 degrees a second, or 45-degree steps; SMAA on the eye images.
    static wwvr_xr_comfort cached{false, 45.0f, 135.0f, false};
    static uint64_t readAt = 0;
    if (g.frames == 0 || g.frames >= readAt) {
        readAt = g.frames + 90;
        @autoreleasepool {
            NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
            cached.snap_turn = [defaults boolForKey:@"vrSnapTurn"];
            const NSInteger snap = [defaults integerForKey:@"vrSnapTurnDegrees"];
            cached.snap_degrees = snap >= 15 && snap <= 90 ? static_cast<float>(snap) : 45.0f;
            const NSInteger speed = [defaults integerForKey:@"vrSmoothTurnSpeed"];
            cached.smooth_speed = speed >= 30 && speed <= 360 ? static_cast<float>(speed) : 135.0f;
            cached.sword_left = [defaults integerForKey:@"vrSwordHand"] == 1;
            NSInteger aa = 2;
            if ([defaults objectForKey:@"vrAntiAliasing"] != nil) {
                aa = std::clamp<NSInteger>([defaults integerForKey:@"vrAntiAliasing"], 0, 2);
            }
            static NSInteger appliedAa = -1;
            if (aa != appliedAa) {
                appliedAa = aa;
                xr_visionos_set_anti_aliasing(static_cast<int>(aa));
            }
        }
    }
    if (comfort != nullptr) {
        *comfort = cached;
    }
}

}  // extern "C"
