// The game in a visionOS window: see wwvr_window.h. Adapted from the TPVR port's
// src/dusk/visionos/visionos_window.cpp (the same aurora, Dawn and window app side).
//
// Data path, per frame:
//   game thread   begin_frame()  waits for the window's tick (the app's RealityKit update)
//                 note_scene()   the camera's projection and focus, if a 3D scene is drawn
//                 scene_drawn()  with the scene mirror: resolve_pass(colour) -> encoder task: the
//                                3D picture before the screen effects (motion blur, depth of field)
//                 before_hud()   resolve_pass(colour + depth) -> encoder task: scene, distance
//                 after_hud()    resolve_pass(colour) -> encoder task: the finished frame
//   render worker the tasks copy the snapshots into the slot's IOSurfaces (Dawn imports them),
//                 then, after the frame's command buffer is submitted, end Dawn's access and
//                 publish the slot with the MTLSharedEvent the reads must wait on.
//   app (main)    wwvr_visionos_window_acquire() takes the newest slot, its GPU reads wait on
//                 that event, and wwvr_visionos_window_release() hands the slot back once they
//                 finish.
// Every Dawn call happens on the render worker (inside encoder tasks and their after-submit
// callbacks), the thread aurora encodes on.

#include "wwvr_window.h"

#include "sense_pad.h"
#include "wwvr_visionos.h"

#include <aurora/aurora.h>
#include <aurora/gfx.hpp>
#include <aurora/mirror.h>
#include <dolphin/gx/GXAurora.h>
#include <dolphin/gx/GXAuroraStereo.h>
#include <webgpu/webgpu_cpp.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#define WINDOW_LOG(...) std::fprintf(stderr, "[WWVR] window: " __VA_ARGS__)

// SwitchWaker's control options (native/include/pc/pc_controls.h, not on the host's include path).
extern "C" void pc_camera_invert_x_set(int on);
extern "C" void pc_camera_invert_y_set(int on);

namespace wwvr::window {
namespace {

std::atomic_bool g_enabled{false};
// The window's 2D/3D choice (wwvr_visionos_set_window_3d): in 2D the window shows the game's own
// frame, and none of the 3D's work is done (no mirror recording, no scene or depth copies, no HUD
// layer). Read once a frame, at its start.
std::atomic_bool g_flat{false};
dispatch_semaphore_t g_tick = dispatch_semaphore_create(0);
// Bumped whenever any slot's surfaces are (re)made: the app drops its textures over them.
std::atomic<uint64_t> g_surfaceGeneration{1};

// One IOSurface the app reads, imported into Dawn.
struct Surface {
    IOSurfaceRef surface = nullptr;
    wgpu::SharedTextureMemory memory;
    wgpu::Texture texture;
    wgpu::TextureFormat format = wgpu::TextureFormat::Undefined;
    uint32_t width = 0, height = 0;
    bool accessOpen = false;
};

enum class SlotState { Free, Writing, Ready, Reading };

struct CameraInfo {
    float tanHalfX = 0, tanHalfY = 0, focus = 0, nearZ = 0, farZ = 0;
    float subject = 0; // the player's nearest view depth (0: none), for the mirror (MarkSubject)
    float sill = 0;    // where the window's foot meets the player's ground (0: none), for it too (MarkSill)
    bool cut = false;  // the camera cut since the frame before (FrameAim.cut), for it too (MarkCut)
};

// The camera's aim, by game frame, for the mirror frame made in it (the window shows a mirror frame
// up to a frame older than its own: the turn has to be its own frame's). Under g_mutex.
struct FrameAim {
    uint32_t gameFrame = 0xFFFFFFFFu;
    float pitch = 0; // how far it looks down (radians; up: negative)
    bool cut = false;
};

// A frame on its way to the app. While Writing it belongs to the game thread (which fills the
// pending fields) and then the render worker; Ready and Reading belong to the app.
struct Slot {
    SlotState state = SlotState::Free;
    Surface scene, distance, final, ui, base;
    wgpu::Buffer uniforms;
    uint64_t serial = 0;
    uint32_t gameFrame = 0;
    CameraInfo camera;
    bool hasScene = false, hasUi = false, hasFinal = false, hasBase = false;
    void* event = nullptr;  // MTLSharedEvent (Dawn's), borrowed
    uint64_t value = 0;
    // Snapshots taken on the game thread, copied on the render worker. pendingHud: the 2D over black
    // and over white (wwvr_window_hud_*), made into the HUD's layer (`ui`).
    wgpu::TextureView pendingScene, pendingDepth, pendingFinal, pendingBase;
    std::array<wgpu::TextureView, 2> pendingHud;
    uint32_t sceneWidth = 0, sceneHeight = 0, finalWidth = 0, finalHeight = 0, hudWidth = 0, hudHeight = 0;
    uint32_t baseWidth = 0, baseHeight = 0;
    // A frame whose 2D went to the HUD's layer: its finished frame is its scene (the same pixels),
    // handed over as the scene's surface rather than copied again.
    bool finalIsScene = false;
};

constexpr size_t kSlots = 4;
std::mutex g_mutex;  // slot states, serials, g_latest
std::array<Slot, kSlots> g_slots;
uint64_t g_nextSerial = 1;
int g_latest = -1;
uint64_t g_handed = 0;

// Game-thread state for the frame being built.
int g_frameSlot = -1;
bool g_sceneThisFrame = false;
bool g_scenePushed = false;  // this frame's scene task is on its way for g_frameSlot
bool g_basePushed = false;   // and its base task (the picture before the screen effects)
bool g_mirrorBegun = false;  // a scene-mirror frame was opened this frame, and must be closed
bool g_hudOpen = false;      // a HUD pass (wwvr_window_hud_begin) is open
bool g_frameFlat = false;    // this frame is 2D (g_flat at its start)
// The window's 3D view scale (wwvr_visionos_set_window_view_scale): wanted, this frame's, taken at
// the camera's view_setup (before the painter's begin_frame, in the game's frame), and the one the
// game's projection (camera_draw) was last made with.
std::atomic<float> g_viewScaleWanted{1.f};
float g_viewScale = 1.f;
// The camera's C-stick directions from the launcher (wwvr_visionos_set_camera_invert): bit 0 left
// and right, bit 1 up and down, -1 none given; the serial counts changes, and the game thread
// takes each once (wwvr_window_sync_camera_invert).
std::atomic<int> g_cameraInvert{-1};
std::atomic<uint32_t> g_cameraInvertSerial{0};
uint32_t g_cameraInvertTaken = 0;
// The window's re-aim as MirrorScene does it (wwvr_visionos_set_window_aim): how much of the
// camera's downward pitch it takes out, at most how much (radians), and how far it raises the eye
// (a share of the camera's height above its focus), and the test runs' turn more (radians). The
// sill (note_scene) is worked out with them.
std::atomic<float> g_aimFraction{1.f}, g_aimCap{20.f * 3.14159265f / 180.f}, g_aimRaise{0.5f}, g_aimExtra{0.f};
// The player this frame (view_setup): his feet and his eyes' height.
bool g_playerPresent = false;
float g_playerFeet[3] = {0.f, 0.f, 0.f};
float g_playerEyeY = 0.f;
bool g_firstPerson = false; // this frame's camera is first person (view_setup)
bool g_eventCamera = false; // and an event's (a cutscene's)
float g_projectionScale = 1.f;
uint32_t g_gameFrame = 0;     // this frame's number (24 bits), shared by its window frame and mirror frame
CameraInfo g_camera;
std::array<FrameAim, 64> g_aims;          // the last 64 frames' (two seconds; by game frame), under g_mutex
float g_lastEye[3] = {}, g_lastLook[3] = {}; // the camera the frame before (a cut's test)
bool g_haveLast = false;

aurora::gfx::EncoderTaskId g_sceneTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_finalTask = aurora::gfx::InvalidEncoderTask;
aurora::gfx::EncoderTaskId g_baseTask = aurora::gfx::InvalidEncoderTask;

struct TaskPayload {
    uint32_t slot;
};

// The copies: a fullscreen triangle that loads the source texel for texel. fs_distance turns
// aurora's reversed-Z depth (near 1, far 0) into the distance from the camera in game units:
// d = n (f - z) / ((f - n) z)  =>  z = n f / (n + d (f - n)).
constexpr const char* kShader = R"(
struct Params { nearZ: f32, farZ: f32, unused0: f32, unused1: f32 };
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var<uniform> params: Params;

@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment fn fs_copy(@builtin(position) at: vec4f) -> @location(0) vec4f {
    return textureLoad(source, vec2i(at.xy), 0);
}

@fragment fn fs_distance(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let depth = textureLoad(source, vec2i(at.xy), 0).r;
    let n = params.nearZ;
    let f = params.farZ;
    let distance = n * f / max(n + depth * (f - n), 1e-6);
    return vec4f(min(distance, 60000.0), depth, 0.0, 1.0);
}
)";

// The HUD's layer from the 2D drawn over black (b = a c) and over white (w = a c + 1 - a): a = 1 -
// (w - b), b the colour premultiplied, whatever blending the game used (the VR panel's matte). The
// game blends in its own (sRGB) values and the window composites in linear ones: the colour is
// unpremultiplied, made linear and premultiplied again, then stored sRGB-encoded for the app's
// sRGB view. A pixel that only adds light (a = 0) is kept as its light.
constexpr const char* kHudShader = R"(
@group(0) @binding(0) var black: texture_2d<f32>;
@group(0) @binding(1) var white: texture_2d<f32>;

@vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

fn to_linear(c: vec3f) -> vec3f {
    return select(pow((c + 0.055) / 1.055, vec3f(2.4)), c / 12.92, c <= vec3f(0.04045));
}

fn to_srgb(c: vec3f) -> vec3f {
    return select(1.055 * pow(c, vec3f(1.0 / 2.4)) - 0.055, c * 12.92, c <= vec3f(0.0031308));
}

@fragment fn fs_hud(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let b = textureLoad(black, vec2i(at.xy), 0).rgb;
    let w = textureLoad(white, vec2i(at.xy), 0).rgb;
    let a = clamp(1.0 - dot(w - b, vec3f(1.0 / 3.0)), 0.0, 1.0);
    var premultiplied = to_linear(b);
    if (a >= 0.004) {
        premultiplied = to_linear(min(b / a, vec3f(1.0))) * a;
    }
    return vec4f(to_srgb(clamp(premultiplied, vec3f(0.0), vec3f(1.0))), a);
}
)";

struct Pipelines {
    wgpu::BindGroupLayout layout, hudLayout;
    wgpu::RenderPipeline copyBgra8, copyRgba16f, distance, hud;
    bool failed = false;
};
Pipelines g_pipelines;

wgpu::RenderPipeline MakePipeline(const wgpu::Device& device, const wgpu::ShaderModule& module,
                                  const wgpu::PipelineLayout& layout, const char* fragment,
                                  wgpu::TextureFormat format) {
    wgpu::ColorTargetState target{};
    target.format = format;
    wgpu::FragmentState fs{};
    fs.module = module;
    fs.entryPoint = fragment;
    fs.targetCount = 1;
    fs.targets = &target;
    wgpu::RenderPipelineDescriptor desc{};
    desc.label = "visionOS window copy";
    desc.layout = layout;
    desc.vertex.module = module;
    desc.vertex.entryPoint = "vs";
    desc.primitive.topology = wgpu::PrimitiveTopology::TriangleList;
    desc.fragment = &fs;
    return device.CreateRenderPipeline(&desc);
}

bool EnsurePipelines(const wgpu::Device& device) {
    if (g_pipelines.copyBgra8 || g_pipelines.failed) {
        return !g_pipelines.failed;
    }
    wgpu::ShaderSourceWGSL wgsl{};
    wgsl.code = kShader;
    wgpu::ShaderModuleDescriptor moduleDesc{};
    moduleDesc.nextInChain = &wgsl;
    moduleDesc.label = "visionOS window copy";
    wgpu::ShaderModule module = device.CreateShaderModule(&moduleDesc);

    std::array<wgpu::BindGroupLayoutEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].visibility = wgpu::ShaderStage::Fragment;
    entries[0].texture.sampleType = wgpu::TextureSampleType::UnfilterableFloat;
    entries[0].texture.viewDimension = wgpu::TextureViewDimension::e2D;
    entries[1].binding = 1;
    entries[1].visibility = wgpu::ShaderStage::Fragment;
    entries[1].buffer.type = wgpu::BufferBindingType::Uniform;
    entries[1].buffer.minBindingSize = 16;
    wgpu::BindGroupLayoutDescriptor layoutDesc{};
    layoutDesc.entryCount = entries.size();
    layoutDesc.entries = entries.data();
    g_pipelines.layout = device.CreateBindGroupLayout(&layoutDesc);
    wgpu::PipelineLayoutDescriptor pipelineLayoutDesc{};
    pipelineLayoutDesc.bindGroupLayoutCount = 1;
    pipelineLayoutDesc.bindGroupLayouts = &g_pipelines.layout;
    wgpu::PipelineLayout layout = device.CreatePipelineLayout(&pipelineLayoutDesc);

    g_pipelines.copyBgra8 = MakePipeline(device, module, layout, "fs_copy", wgpu::TextureFormat::BGRA8Unorm);
    g_pipelines.copyRgba16f = MakePipeline(device, module, layout, "fs_copy", wgpu::TextureFormat::RGBA16Float);
    g_pipelines.distance = MakePipeline(device, module, layout, "fs_distance", wgpu::TextureFormat::RGBA16Float);

    // The HUD's layer: two textures in.
    wgpu::ShaderSourceWGSL hudWgsl{};
    hudWgsl.code = kHudShader;
    wgpu::ShaderModuleDescriptor hudModuleDesc{};
    hudModuleDesc.nextInChain = &hudWgsl;
    hudModuleDesc.label = "visionOS window HUD";
    wgpu::ShaderModule hudModule = device.CreateShaderModule(&hudModuleDesc);
    std::array<wgpu::BindGroupLayoutEntry, 2> hudEntries{};
    for (uint32_t i = 0; i < hudEntries.size(); ++i) {
        hudEntries[i].binding = i;
        hudEntries[i].visibility = wgpu::ShaderStage::Fragment;
        hudEntries[i].texture.sampleType = wgpu::TextureSampleType::UnfilterableFloat;
        hudEntries[i].texture.viewDimension = wgpu::TextureViewDimension::e2D;
    }
    wgpu::BindGroupLayoutDescriptor hudLayoutDesc{};
    hudLayoutDesc.entryCount = hudEntries.size();
    hudLayoutDesc.entries = hudEntries.data();
    g_pipelines.hudLayout = device.CreateBindGroupLayout(&hudLayoutDesc);
    wgpu::PipelineLayoutDescriptor hudPipelineLayoutDesc{};
    hudPipelineLayoutDesc.bindGroupLayoutCount = 1;
    hudPipelineLayoutDesc.bindGroupLayouts = &g_pipelines.hudLayout;
    wgpu::PipelineLayout hudPipelineLayout = device.CreatePipelineLayout(&hudPipelineLayoutDesc);
    g_pipelines.hud = MakePipeline(device, hudModule, hudPipelineLayout, "fs_hud", wgpu::TextureFormat::BGRA8Unorm);
    g_pipelines.failed = !g_pipelines.copyBgra8 || !g_pipelines.distance || !g_pipelines.hud;
    if (g_pipelines.failed) {
        WINDOW_LOG("copy pipelines failed\n");
    }
    return !g_pipelines.failed;
}

IOSurfaceRef CreateSurface(uint32_t width, uint32_t height, uint32_t fourcc, int bytesPerElement) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const auto set = [&](CFStringRef key, int value) {
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
        CFDictionarySetValue(properties, key, number);
        CFRelease(number);
    };
    set(kIOSurfaceWidth, static_cast<int>(width));
    set(kIOSurfaceHeight, static_cast<int>(height));
    set(kIOSurfaceBytesPerElement, bytesPerElement);
    set(kIOSurfacePixelFormat, static_cast<int>(fourcc));
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}

void Release(Surface& surface) {
    surface.texture = nullptr;
    surface.memory = nullptr;
    if (surface.surface != nullptr) {
        CFRelease(surface.surface);
    }
    surface = Surface{};
}

// An IOSurface of this size and format, imported into Dawn (made, or remade on a size change).
bool EnsureSurface(const wgpu::Device& device, Slot& slot, Surface& surface, uint32_t width, uint32_t height,
                   bool halfFloat) {
    if (surface.surface != nullptr && surface.width == width && surface.height == height) {
        return surface.texture != nullptr;
    }
    Release(surface);
    surface.surface = halfFloat ? CreateSurface(width, height, 'RGhA', 8) : CreateSurface(width, height, 'BGRA', 4);
    if (surface.surface == nullptr) {
        WINDOW_LOG("IOSurfaceCreate %ux%u failed\n", width, height);
        return false;
    }
    wgpu::SharedTextureMemoryIOSurfaceDescriptor ioDesc{};
    ioDesc.ioSurface = surface.surface;
    wgpu::SharedTextureMemoryDescriptor memoryDesc{};
    memoryDesc.nextInChain = &ioDesc;
    memoryDesc.label = "visionOS window surface";
    surface.memory = device.ImportSharedTextureMemory(&memoryDesc);
    if (surface.memory) {
        wgpu::SharedTextureMemoryProperties props{};
        surface.memory.GetProperties(&props);
        wgpu::TextureDescriptor textureDesc{};
        textureDesc.label = "visionOS window surface";
        textureDesc.usage = wgpu::TextureUsage::RenderAttachment;
        textureDesc.size = {width, height, 1};
        textureDesc.format = props.format;
        surface.texture = surface.memory.CreateTexture(&textureDesc);
        surface.format = props.format;
    }
    if (!surface.texture) {
        WINDOW_LOG("Dawn could not import a %ux%u window surface\n", width, height);
        Release(surface);
        return false;
    }
    surface.width = width;
    surface.height = height;
    g_surfaceGeneration.fetch_add(1);
    return true;
}

bool BeginAccess(Surface& surface) {
    if (surface.accessOpen) {
        return true;
    }
    wgpu::SharedTextureMemoryBeginAccessDescriptor begin{};
    begin.initialized = true;
    if (surface.memory.BeginAccess(surface.texture, &begin) != wgpu::Status::Success) {
        WINDOW_LOG("BeginAccess failed\n");
        return false;
    }
    surface.accessOpen = true;
    return true;
}

// Ends Dawn's access, keeping the MTLSharedEvent and the value its writes complete at.
void EndAccess(Surface& surface, void*& event, uint64_t& value) {
    if (!surface.accessOpen) {
        return;
    }
    surface.accessOpen = false;
    wgpu::SharedTextureMemoryEndAccessState end{};
    surface.memory.EndAccess(surface.texture, &end);
    for (size_t i = 0; i < end.fenceCount && i < end.signaledValueCount; ++i) {
        wgpu::SharedFenceMTLSharedEventExportInfo metal{};
        wgpu::SharedFenceExportInfo info{};
        info.nextInChain = &metal;
        end.fences[i].ExportInfo(&info);
        if (info.type == wgpu::SharedFenceType::MTLSharedEvent && metal.sharedEvent != nullptr) {
            event = metal.sharedEvent;
            value = std::max(value, end.signaledValues[i]);
        }
    }
}

void Draw(const wgpu::Device& device, wgpu::CommandEncoder& encoder, const wgpu::RenderPipeline& pipeline,
          const wgpu::TextureView& source, const wgpu::Buffer& uniforms, Surface& target) {
    std::array<wgpu::BindGroupEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].textureView = source;
    entries[1].binding = 1;
    entries[1].buffer = uniforms;
    entries[1].size = 16;
    wgpu::BindGroupDescriptor groupDesc{};
    groupDesc.layout = g_pipelines.layout;
    groupDesc.entryCount = entries.size();
    groupDesc.entries = entries.data();
    wgpu::BindGroup group = device.CreateBindGroup(&groupDesc);

    wgpu::RenderPassColorAttachment colour{};
    colour.view = target.texture.CreateView();
    colour.loadOp = wgpu::LoadOp::Clear;
    colour.storeOp = wgpu::StoreOp::Store;
    colour.clearValue = {0, 0, 0, 0};
    wgpu::RenderPassDescriptor passDesc{};
    passDesc.label = "visionOS window copy";
    passDesc.colorAttachmentCount = 1;
    passDesc.colorAttachments = &colour;
    wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&passDesc);
    pass.SetPipeline(pipeline);
    pass.SetBindGroup(0, group);
    pass.Draw(3);
    pass.End();
}

// The HUD's layer into `target` (BGRA8) from the 2D over black and over white.
void DrawHud(const wgpu::Device& device, wgpu::CommandEncoder& encoder, const wgpu::TextureView& black,
             const wgpu::TextureView& white, Surface& target) {
    std::array<wgpu::BindGroupEntry, 2> entries{};
    entries[0].binding = 0;
    entries[0].textureView = black;
    entries[1].binding = 1;
    entries[1].textureView = white;
    wgpu::BindGroupDescriptor groupDesc{};
    groupDesc.layout = g_pipelines.hudLayout;
    groupDesc.entryCount = entries.size();
    groupDesc.entries = entries.data();
    wgpu::BindGroup group = device.CreateBindGroup(&groupDesc);

    wgpu::RenderPassColorAttachment colour{};
    colour.view = target.texture.CreateView();
    colour.loadOp = wgpu::LoadOp::Clear;
    colour.storeOp = wgpu::StoreOp::Store;
    colour.clearValue = {0, 0, 0, 0};
    wgpu::RenderPassDescriptor passDesc{};
    passDesc.label = "visionOS window HUD";
    passDesc.colorAttachmentCount = 1;
    passDesc.colorAttachments = &colour;
    wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&passDesc);
    pass.SetPipeline(g_pipelines.hud);
    pass.SetBindGroup(0, group);
    pass.Draw(3);
    pass.End();
}

const wgpu::RenderPipeline& CopyPipelineFor(const Surface& target) {
    return target.format == wgpu::TextureFormat::RGBA16Float ? g_pipelines.copyRgba16f : g_pipelines.copyBgra8;
}

void EnsureUniforms(const wgpu::Device& device, Slot& slot) {
    if (!slot.uniforms) {
        wgpu::BufferDescriptor desc{};
        desc.label = "visionOS window params";
        desc.size = 16;
        desc.usage = wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst;
        slot.uniforms = device.CreateBuffer(&desc);
    }
}

// Render worker: the scene and its distances into the slot.
void SceneTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
               size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasScene = false;
    if (!EnsurePipelines(ctx.device) || !slot.pendingScene || !slot.pendingDepth) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    const float params[4] = {slot.camera.nearZ, slot.camera.farZ, 0, 0};
    ctx.queue.WriteBuffer(slot.uniforms, 0, params, sizeof(params));
    if (!EnsureSurface(ctx.device, slot, slot.scene, slot.sceneWidth, slot.sceneHeight, false) ||
        !EnsureSurface(ctx.device, slot, slot.distance, slot.sceneWidth, slot.sceneHeight, true) ||
        !BeginAccess(slot.scene) || !BeginAccess(slot.distance)) {
        return;
    }
    Draw(ctx.device, encoder, CopyPipelineFor(slot.scene), slot.pendingScene, slot.uniforms, slot.scene);
    Draw(ctx.device, encoder, g_pipelines.distance, slot.pendingDepth, slot.uniforms, slot.distance);
    slot.hasScene = true;
}

// Render worker: the 3D picture before the screen effects into the slot.
void BaseTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
              size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasBase = false;
    if (!EnsurePipelines(ctx.device) || !slot.pendingBase) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    if (!EnsureSurface(ctx.device, slot, slot.base, slot.baseWidth, slot.baseHeight, false) ||
        !BeginAccess(slot.base)) {
        return;
    }
    Draw(ctx.device, encoder, CopyPipelineFor(slot.base), slot.pendingBase, slot.uniforms, slot.base);
    slot.hasBase = true;
}

// Render worker: the finished frame and the HUD's layer into the slot.
void FinalTask(const aurora::gfx::EncoderTaskContext& ctx, const wgpu::CommandEncoder& cmd, const void* payload,
               size_t, void*) {
    Slot& slot = g_slots[static_cast<const TaskPayload*>(payload)->slot];
    wgpu::CommandEncoder encoder = cmd;
    slot.hasFinal = false;
    slot.hasUi = false;
    if (!EnsurePipelines(ctx.device) || (!slot.pendingFinal && !(slot.finalIsScene && slot.hasScene))) {
        return;
    }
    EnsureUniforms(ctx.device, slot);
    if (slot.finalIsScene) {
        slot.hasFinal = slot.hasScene;
    } else if (EnsureSurface(ctx.device, slot, slot.final, slot.finalWidth, slot.finalHeight, false) &&
               BeginAccess(slot.final)) {
        Draw(ctx.device, encoder, CopyPipelineFor(slot.final), slot.pendingFinal, slot.uniforms, slot.final);
        slot.hasFinal = true;
    }
    if (slot.pendingHud[0] && slot.pendingHud[1] &&
        EnsureSurface(ctx.device, slot, slot.ui, slot.hudWidth, slot.hudHeight, false) && BeginAccess(slot.ui)) {
        DrawHud(ctx.device, encoder, slot.pendingHud[0], slot.pendingHud[1], slot.ui);
        slot.hasUi = true;
    }
}

// Render worker, after the frame's command buffer went to the GPU: end Dawn's access and hand
// the slot to the app.
void FinalSubmitted(const aurora::gfx::EncoderTaskCompletionContext&, const void* payload, size_t, void*) {
    const uint32_t index = static_cast<const TaskPayload*>(payload)->slot;
    Slot& slot = g_slots[index];
    void* event = nullptr;
    uint64_t value = 0;
    EndAccess(slot.scene, event, value);
    EndAccess(slot.distance, event, value);
    EndAccess(slot.final, event, value);
    EndAccess(slot.ui, event, value);
    EndAccess(slot.base, event, value);
    slot.pendingScene = nullptr;
    slot.pendingBase = nullptr;
    slot.pendingDepth = nullptr;
    slot.pendingFinal = nullptr;
    slot.pendingHud = {};
    std::lock_guard lock(g_mutex);
    if (!slot.hasFinal) {
        slot.state = SlotState::Free;
        return;
    }
    slot.event = event;
    slot.value = value;
    slot.serial = g_nextSerial++;
    if (g_latest >= 0 && g_latest != static_cast<int>(index) && g_slots[g_latest].state == SlotState::Ready) {
        g_slots[g_latest].state = SlotState::Free;  // never shown: a newer frame replaces it
    }
    slot.state = SlotState::Ready;
    g_latest = static_cast<int>(index);
}

void RegisterTasks() {
    if (g_sceneTask != aurora::gfx::InvalidEncoderTask) {
        return;
    }
    aurora::gfx::EncoderTaskDescriptor scene{};
    scene.label = "visionOS window scene";
    scene.callback = &SceneTask;
    g_sceneTask = aurora::gfx::register_encoder_task_type(scene);
    aurora::gfx::EncoderTaskDescriptor final{};
    final.label = "visionOS window frame";
    final.callback = &FinalTask;
    final.afterSubmit = &FinalSubmitted;
    g_finalTask = aurora::gfx::register_encoder_task_type(final);
    aurora::gfx::EncoderTaskDescriptor base{};
    base.label = "visionOS window base";
    base.callback = &BaseTask;
    g_baseTask = aurora::gfx::register_encoder_task_type(base);
}

// Game thread: a free slot for this frame, or -1 (the app holds them all: skip this frame).
int ClaimSlot() {
    if (g_frameSlot >= 0) {
        return g_frameSlot;
    }
    std::lock_guard lock(g_mutex);
    for (size_t i = 0; i < kSlots; ++i) {
        if (g_slots[i].state == SlotState::Free) {
            g_slots[i].state = SlotState::Writing;
            // Nothing of an earlier frame's HUD layer in it (a frame whose task couldn't be pushed
            // gave its slot back with them set).
            g_slots[i].pendingHud = {};
            g_slots[i].finalIsScene = false;
            g_frameSlot = static_cast<int>(i);
            return g_frameSlot;
        }
    }
    return -1;
}


}  // namespace

void set_enabled(bool enabled) {
    g_enabled.store(enabled);
}

}  // namespace wwvr::window

using namespace wwvr::window;

extern "C" {

bool wwvr_window_enabled(void) {
    return g_enabled.load(std::memory_order_relaxed);
}

void wwvr_window_begin_frame(void) {
    if (!wwvr_window_enabled()) {
        return;
    }
    static bool started = false;
    if (!started) {
        started = true;
        // Nobody sees the offscreen SDL window's surface.
        aurora::gfx::set_surface_present_suppressed(true);
        RegisterTasks();
        WINDOW_LOG("window mode: the game paces to the window and hands it each frame\n");
    }
    // A frame per window update: wait for the next, at most 100 ms (a hidden window stops
    // ticking), then forget any that piled up so the game never races ahead to catch up.
    dispatch_semaphore_wait(g_tick, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    while (dispatch_semaphore_wait(g_tick, DISPATCH_TIME_NOW) == 0) {
    }
    g_frameSlot = -1;
    g_sceneThisFrame = false;
    g_scenePushed = false;
    g_basePushed = false;
    g_hudOpen = false;
    g_frameFlat = g_flat.load(std::memory_order_relaxed);
    g_gameFrame = (g_gameFrame + 1) & 0xFFFFFFu;
    // The Sense controllers, if any, as a gamepad (no controller tracking outside a Full Space).
    sense_pad::update_sdl_gamepad();
    // The scene mirror records the frame's draws from here to scene_drawn() / before_hud(); in 2D
    // it isn't asked to (it keeps what it knows, so 3D comes back without sending it all again).
    if (aurora::mirror::enabled() && !g_frameFlat) {
        GXAuroraMirrorMark(AURORA_MIRROR_MARK_BEGIN, static_cast<float>(g_gameFrame));
        // How much wider than its picture the frame is drawn (aurora 0109's view scale mark).
        GXAuroraMirrorMark(aurora::mirror::MarkViewScale, g_viewScale);
        g_mirrorBegun = true;
    }
}

void wwvr_window_note_scene(float proj00, float proj11, float eye_x, float eye_y, float eye_z, float center_x,
                            float center_y, float center_z, float near_z, float far_z) {
    // In 2D the frame has no scene for the window: the finished frame is all it takes.
    if (!wwvr_window_enabled() || g_frameFlat) {
        return;
    }
    g_sceneThisFrame = true;
    // The picture's framing: the projection drawn with, narrowed by the view scale.
    g_camera.tanHalfX = proj00 != 0 ? 1.0f / std::fabs(proj00) / g_viewScale : 1.0f;
    g_camera.tanHalfY = proj11 != 0 ? 1.0f / std::fabs(proj11) / g_viewScale : 0.75f;
    const float dx = center_x - eye_x, dy = center_y - eye_y, dz = center_z - eye_z;
    g_camera.focus = std::sqrt(dx * dx + dy * dy + dz * dz);
    // How far it looks down (the window turns its world more level: MirrorScene.place); not in first
    // person, where the player aims, nor in an event, which the game frames itself. And whether the
    // camera cut since the frame before: it looks more than 12 degrees elsewhere, or its eye moved by
    // more than a quarter of the focus (a C-stick turn is a few degrees a frame).
    const float level = std::sqrt(dx * dx + dz * dz);
    FrameAim aim{g_gameFrame, 0.f, false};
    if (!g_firstPerson && !g_eventCamera && g_camera.focus > 0.f) {
        aim.pitch = std::atan2(-dy, level);
    }
    if (g_camera.focus > 0.f) {
        const float look[3] = {dx / g_camera.focus, dy / g_camera.focus, dz / g_camera.focus};
        const float ex = eye_x - g_lastEye[0], ey = eye_y - g_lastEye[1], ez = eye_z - g_lastEye[2];
        aim.cut = g_haveLast && (look[0] * g_lastLook[0] + look[1] * g_lastLook[1] + look[2] * g_lastLook[2] <
                                     std::cos(12.f * 3.14159265f / 180.f) ||
                                 ex * ex + ey * ey + ez * ez > 0.0625f * g_camera.focus * g_camera.focus);
        std::copy(look, look + 3, g_lastLook);
        g_lastEye[0] = eye_x, g_lastEye[1] = eye_y, g_lastEye[2] = eye_z;
        g_haveLast = true;
    }
    {
        std::lock_guard lock(g_mutex);
        g_aims[g_gameFrame % g_aims.size()] = aim;
    }
    g_camera.cut = aim.cut;
    g_camera.nearZ = near_z;
    g_camera.farZ = far_z;
    // The player, as this camera sees him (aurora 0111), when he's in the picture or just outside
    // it; not in first person, where he's the camera. Off the picture he's no one's subject, and the
    // ground at his feet needn't be the picture's (an event's camera elsewhere).
    g_camera.subject = 0;
    g_camera.sill = 0;
    if (g_playerPresent && !g_firstPerson && g_camera.focus > 0.f && level > 1e-3f * g_camera.focus) {
        const float f = g_camera.focus;
        const float look[3] = {dx / f, dy / f, dz / f};
        const float right[3] = {-dz / level, 0.f, dx / level}; // level: the game's play cameras don't bank
        const float up[3] = {-right[2] * look[1], right[2] * look[0] - right[0] * look[2], right[0] * look[1]};
        // How near the camera he comes (his feet, middle and the top of his cap, less his girth):
        // the mirror keeps him whole (a lock-on or a camera pushed in behind him can put him well
        // short of the camera's focus, where the window cuts off what would come out too far).
        const float feet = g_playerFeet[1];
        const float tall = g_playerEyeY > feet + 20.f ? 1.15f * (g_playerEyeY - feet) : 110.f;
        float nearest = INFINITY;
        bool seen = false;
        for (const float rise : {0.f, 0.5f * tall, tall}) {
            const float rel[3] = {g_playerFeet[0] - eye_x, feet + rise - eye_y, g_playerFeet[2] - eye_z};
            const float depth = rel[0] * look[0] + rel[1] * look[1] + rel[2] * look[2];
            const float across = rel[0] * right[0] + rel[1] * right[1] + rel[2] * right[2];
            const float upward = rel[0] * up[0] + rel[1] * up[1] + rel[2] * up[2];
            nearest = std::min(nearest, depth);
            seen = seen || (depth > 0.f && std::fabs(across) <= 1.25f * g_camera.tanHalfX * depth &&
                            std::fabs(upward) <= 1.25f * g_camera.tanHalfY * depth);
        }
        g_camera.subject = seen && std::isfinite(nearest) ? std::max(nearest - 40.f, 0.f) : 0.f;
        // The sill (MarkSill): the glass's distance P at which the ground at his feet, taken as
        // level, passes through the middle of the window's foot in the window's re-aimed view
        // (MirrorScene.place: turned by t about the focus, lowered by L). The glass comes no farther
        // than that, so the ground there lies on the glass and never comes out in front of it. With
        // the camera H above his feet, looking down by p, its focus f away and the picture's
        // half-height tan y, the window's foot is P tan y below its middle, which lies at the turned
        // view's middle:
        //   P (tan y cos(p - t) + sin(p - t)) = H + L cos(p - t) + f sin(p - t) - f sin p,
        // which, turned by all of the pitch (t = p), is P tan y = H - f sin p + L: the height above
        // his feet of the eye line through the window's middle. L = raise x f sin t, at most
        // 0.4 P tan y and what keeps the drawn view's top at the window's top (MirrorScene.place's
        // limits; L's share of P converges in a few steps). Unturned (an event's camera, t = 0), the
        // line of sight through the picture's foot meets his ground at P (TPVR's sill). None with
        // the foot not looking down at the ground.
        const float tanY = g_camera.tanHalfY;
        const float height = eye_y - feet;
        const float p = std::atan2(-dy, level);
        const float t = (g_eventCamera ? 0.f
                                       : g_aimFraction.load(std::memory_order_relaxed) *
                                             std::clamp(p, 0.f, g_aimCap.load(std::memory_order_relaxed))) +
                        g_aimExtra.load(std::memory_order_relaxed);
        const float raise = g_aimRaise.load(std::memory_order_relaxed);
        const float denominator = tanY * std::cos(p - t) + std::sin(p - t);
        if (seen && height > 0.f && tanY > 0.f && denominator > 1e-3f) {
            const float above = f * std::sin(t); // the camera's height above its focus, turned
            const float drawnTop =
                std::max(0.f, tanY - std::tan(std::atan(g_viewScale * tanY) - t)); // past the drawn top
            float plane = 0.85f * f;
            for (int i = 0; i < 8 && plane > 0.f; ++i) {
                const float lowered =
                    std::max(0.f, std::min({raise * above, 0.4f * plane * tanY, above - plane * drawnTop}));
                plane = (height + lowered * std::cos(p - t) + f * std::sin(p - t) - f * std::sin(p)) / denominator;
            }
            g_camera.sill = std::isfinite(plane) && plane > 0.f ? plane : 0.f;
        }
    }
}

bool wwvr_window_mirroring(void) {
    return g_mirrorBegun;
}

void wwvr_window_camera_invert_to_env(void) {
    g_cameraInvertTaken = g_cameraInvertSerial.load(std::memory_order_acquire);
    const int invert = g_cameraInvert.load(std::memory_order_relaxed);
    if (invert >= 0) {
        setenv("COS_CAMERA_INVERT_X", (invert & 1) != 0 ? "1" : "0", 1);
        setenv("COS_CAMERA_INVERT_Y", (invert & 2) != 0 ? "1" : "0", 1);
    }
}

void wwvr_window_sync_camera_invert(void) {
    const uint32_t serial = g_cameraInvertSerial.load(std::memory_order_acquire);
    if (serial == g_cameraInvertTaken) {
        return;
    }
    g_cameraInvertTaken = serial;
    const int invert = g_cameraInvert.load(std::memory_order_relaxed);
    if (invert >= 0) {
        pc_camera_invert_x_set((invert & 1) != 0);
        pc_camera_invert_y_set((invert & 2) != 0);
        WINDOW_LOG("camera: left and right %s, up and down %s\n", (invert & 1) != 0 ? "modern" : "as on the GameCube",
                   (invert & 2) != 0 ? "inverted" : "as on the GameCube");
    }
}

void wwvr_window_set_player(bool present, float x, float y, float z, float eye_y) {
    g_playerPresent = present && std::isfinite(x) && std::isfinite(y) && std::isfinite(z);
    g_playerFeet[0] = x, g_playerFeet[1] = y, g_playerFeet[2] = z;
    g_playerEyeY = std::isfinite(eye_y) ? eye_y : y;
}

void wwvr_window_set_event_camera(bool event) {
    g_eventCamera = event;
}

void wwvr_window_take_view_scale(bool first_person) {
    g_firstPerson = first_person;
    // In 2D, and in first person, the game draws as it always does.
    const bool wide = wwvr_window_enabled() && !first_person && !g_flat.load(std::memory_order_relaxed);
    const float wanted = wide ? g_viewScaleWanted.load(std::memory_order_relaxed) : 1.f;
    g_viewScale = std::isfinite(wanted) ? std::clamp(wanted, 1.f, 3.f) : 1.f;
}

float wwvr_window_fovy(float fovy, bool projection) {
    const float scale = wwvr_window_enabled() ? g_viewScale : 1.f;
    if (projection) {
        g_projectionScale = scale;
    }
    if (scale == 1.f) {
        return fovy;
    }
    constexpr float kRadians = 3.14159265f / 180.f;
    const float half = std::tan(std::clamp(fovy, 1.f, 170.f) * 0.5f * kRadians) * scale;
    return std::min(2.f * std::atan(half) / kRadians, 170.f);
}

float wwvr_window_projection_scale(void) {
    return g_projectionScale;
}

void wwvr_window_scene_drawn(void) {
    if (!g_mirrorBegun) {
        return;
    }
    // The scene mirror's frame ends here, once the snapshot is taken (its resolve waits for the
    // FIFO; the mirror's finishing work then overlaps the screen effects and the HUD).
    struct CloseMirror {
        ~CloseMirror() {
            g_mirrorBegun = false;
            if (g_sceneThisFrame) {
                GXAuroraMirrorMark(aurora::mirror::MarkSubject, g_camera.subject);
                GXAuroraMirrorMark(aurora::mirror::MarkSill, g_camera.sill);
                GXAuroraMirrorMark(aurora::mirror::MarkFramed, g_eventCamera ? 1.f : 0.f);
                GXAuroraMirrorMark(aurora::mirror::MarkCut, g_camera.cut ? 1.f : 0.f);
            }
            GXAuroraMirrorMark(g_sceneThisFrame ? AURORA_MIRROR_MARK_END : AURORA_MIRROR_MARK_NO_SCENE,
                               g_camera.focus);
        }
    } closeMirror;
    if (!wwvr_window_enabled() || !g_sceneThisFrame) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    aurora::gfx::ResolvedTargets targets;
    if (!aurora::gfx::resolve_pass({.color = true}, targets) || !targets.color) {
        return;
    }
    Slot& slot = g_slots[index];
    slot.pendingBase = targets.color;
    slot.baseWidth = targets.width;
    slot.baseHeight = targets.height;
    const TaskPayload payload{static_cast<uint32_t>(index)};
    g_basePushed = aurora::gfx::push_encoder_task(g_baseTask, &payload, sizeof(payload));
}

void wwvr_window_before_hud(void) {
    // The scene mirror's frame ends here if scene_drawn() didn't end it, whatever happens below,
    // once the snapshots are taken.
    struct CloseMirror {
        ~CloseMirror() {
            if (g_mirrorBegun) {
                g_mirrorBegun = false;
                if (g_sceneThisFrame) {
                    GXAuroraMirrorMark(aurora::mirror::MarkSubject, g_camera.subject);
                    GXAuroraMirrorMark(aurora::mirror::MarkSill, g_camera.sill);
                    GXAuroraMirrorMark(aurora::mirror::MarkFramed, g_eventCamera ? 1.f : 0.f);
                    GXAuroraMirrorMark(aurora::mirror::MarkCut, g_camera.cut ? 1.f : 0.f);
                }
                GXAuroraMirrorMark(g_sceneThisFrame ? AURORA_MIRROR_MARK_END : AURORA_MIRROR_MARK_NO_SCENE,
                                   g_camera.focus);
            }
        }
    } closeMirror;
    if (!wwvr_window_enabled() || !g_sceneThisFrame) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    aurora::gfx::ResolvedTargets targets;
    if (!aurora::gfx::resolve_pass({.color = true, .depth = true}, targets) || !targets.color || !targets.depth) {
        return;
    }
    Slot& slot = g_slots[index];
    slot.pendingScene = targets.color;
    slot.pendingDepth = targets.depth;
    slot.sceneWidth = targets.width;
    slot.sceneHeight = targets.height;
    slot.camera = g_camera;
    const TaskPayload payload{static_cast<uint32_t>(index)};
    g_scenePushed = aurora::gfx::push_encoder_task(g_sceneTask, &payload, sizeof(payload));
}

void wwvr_window_after_hud(void) {
    if (!wwvr_window_enabled()) {
        return;
    }
    const int index = ClaimSlot();
    if (index < 0) {
        return;
    }
    Slot& slot = g_slots[index];
    if (g_sceneThisFrame && !g_scenePushed) {
        // A 3D frame whose scene didn't make it into this slot (no slot was free before the HUD,
        // or the snapshot failed): its finished frame and scene wouldn't match. Skip it. If its
        // base task is queued, that still uses the slot: the final task, with nothing to copy,
        // hands it back on the render worker after it.
        if (g_basePushed) {
            slot.pendingFinal = nullptr;
            slot.pendingHud = {};
            slot.finalIsScene = false;
            const TaskPayload payload{static_cast<uint32_t>(index)};
            if (aurora::gfx::push_encoder_task(g_finalTask, &payload, sizeof(payload))) {
                return;
            }
        }
        std::lock_guard lock(g_mutex);
        slot.state = SlotState::Free;
        g_frameSlot = -1;
        return;
    }
    if (!g_sceneThisFrame) {
        // No scene task for this slot this frame: don't let its last use's scene through.
        slot.hasScene = false;
        slot.pendingScene = nullptr;
        slot.pendingDepth = nullptr;
    }
    if (!g_basePushed) {
        slot.hasBase = false;
        slot.pendingBase = nullptr;
    }
    // The HUD's layer, if both its passes were drawn this frame (wwvr_window_hud_*); the finished
    // frame is then the scene (nothing was drawn over it). (SwitchWaker's own menus, ImGui, draw
    // over the window's surface at present, outside the game's frame: none in the window yet.)
    if (!wwvr_window_hud_split() || !slot.pendingHud[0] || !slot.pendingHud[1]) {
        slot.pendingHud = {};
    }
    slot.finalIsScene = static_cast<bool>(slot.pendingHud[0]);
    aurora::gfx::ResolvedTargets targets;
    if (slot.finalIsScene) {
        slot.pendingFinal = nullptr;
    } else if (aurora::gfx::resolve_pass({.color = true}, targets) && targets.color) {
        slot.pendingFinal = targets.color;
        slot.finalWidth = targets.width;
        slot.finalHeight = targets.height;
    } else {
        slot.pendingFinal = nullptr;
    }
    slot.gameFrame = g_gameFrame;
    const TaskPayload payload{static_cast<uint32_t>(index)};
    if (!aurora::gfx::push_encoder_task(g_finalTask, &payload, sizeof(payload))) {
        // No pass to put it in: the scene task (if any) still ran, so its access ends with the next
        // frame's publish; give the slot back now.
        std::lock_guard lock(g_mutex);
        slot.state = SlotState::Free;
    }
}

bool wwvr_window_hud_split(void) {
#if TARGET_OS_SIMULATOR
    // Test runs: WWVR_TEST_WINDOW_HUD=frame finds the HUD from the finished frame, as before.
    static const bool s_fromFrame = [] {
        const char* value = std::getenv("WWVR_TEST_WINDOW_HUD");
        return value != nullptr && std::strcmp(value, "frame") == 0;
    }();
    if (s_fromFrame) {
        return false;
    }
#endif
    // A frame whose scene is on its way in this frame's slot (before_hud): its finished frame goes
    // with it, and the 2D goes to the HUD's own layer.
    return wwvr_window_enabled() && g_scenePushed && g_frameSlot >= 0;
}

bool wwvr_window_hud_begin(int pass) {
    if (!wwvr_window_hud_split() || pass < 0 || pass > 1 || g_hudOpen) {
        return false;
    }
    const Slot& slot = g_slots[g_frameSlot];
    if (slot.sceneWidth == 0 || slot.sceneHeight == 0 ||
        !aurora::gfx::create_pass(slot.sceneWidth, slot.sceneHeight)) {
        return false;
    }
    g_hudOpen = true;
    // The game's viewports and scissors as on the EFB, so the 2D lies in the pass as in the frame.
    GXAuroraSetOffscreenNativeLogical(GX_TRUE);
    return true;
}

void wwvr_window_hud_end(int pass) {
    if (!g_hudOpen) {
        return;
    }
    g_hudOpen = false;
    GXAuroraSetOffscreenNativeLogical(GX_FALSE);
    aurora::gfx::ResolvedTargets targets;
    Slot& slot = g_slots[g_frameSlot];
    if (aurora::gfx::resolve_pass({.color = true}, targets) && targets.color && pass >= 0 && pass <= 1) {
        slot.pendingHud[pass] = targets.color;
        slot.hudWidth = targets.width;
        slot.hudHeight = targets.height;
    } else if (pass >= 0 && pass <= 1) {
        slot.pendingHud[pass] = nullptr;
    }
}

}  // extern "C"


extern "C" {

void wwvr_visionos_set_window_mode(bool enabled) {
    wwvr::window::set_enabled(enabled);
}

void wwvr_visionos_window_tick(void) {
    dispatch_semaphore_signal(g_tick);
}

bool wwvr_visionos_window_acquire(wwvr_visionos_window_frame* frame) {
    if (frame == nullptr) {
        return false;
    }
    std::lock_guard lock(g_mutex);
    if (g_latest < 0) {
        return false;
    }
    Slot& slot = g_slots[g_latest];
    if (slot.state != SlotState::Ready || slot.serial == g_handed) {
        return false;
    }
    slot.state = SlotState::Reading;
    g_handed = slot.serial;
    *frame = wwvr_visionos_window_frame{};
    frame->serial = slot.serial;
    frame->generation = g_surfaceGeneration.load();
    frame->scene = slot.hasScene ? slot.scene.surface : nullptr;
    frame->distance = slot.hasScene ? slot.distance.surface : nullptr;
    frame->final = slot.finalIsScene ? slot.scene.surface : slot.final.surface;
    frame->ui = slot.hasUi ? slot.ui.surface : nullptr;
    frame->base = slot.hasScene && slot.hasBase ? slot.base.surface : nullptr;
    frame->event = slot.event;
    frame->value = slot.value;
    frame->tan_half_x = slot.camera.tanHalfX;
    frame->tan_half_y = slot.camera.tanHalfY;
    frame->focus = slot.camera.focus;
    frame->game_frame = slot.gameFrame;
    return true;
}

void wwvr_visionos_set_mirror_enabled(bool enabled) {
    aurora::mirror::set_enabled(enabled);
}

void wwvr_visionos_set_window_3d(bool three_d) {
    wwvr::window::g_flat.store(!three_d, std::memory_order_relaxed);
}

void wwvr_visionos_set_window_aim(float fraction, float cap, float raise, float extra) {
    wwvr::window::g_aimFraction.store(std::isfinite(fraction) ? fraction : 1.f, std::memory_order_relaxed);
    wwvr::window::g_aimCap.store(std::isfinite(cap) ? std::max(cap, 0.f) : 0.f, std::memory_order_relaxed);
    wwvr::window::g_aimRaise.store(std::isfinite(raise) ? raise : 0.f, std::memory_order_relaxed);
    wwvr::window::g_aimExtra.store(std::isfinite(extra) ? extra : 0.f, std::memory_order_relaxed);
}

void wwvr_visionos_set_camera_invert(bool invert_x, bool invert_y) {
    wwvr::window::g_cameraInvert.store((invert_x ? 1 : 0) | (invert_y ? 2 : 0), std::memory_order_relaxed);
    wwvr::window::g_cameraInvertSerial.fetch_add(1, std::memory_order_release);
}

void wwvr_visionos_set_window_view_scale(float scale) {
    wwvr::window::g_viewScaleWanted.store(scale, std::memory_order_relaxed);
}

void wwvr_visionos_set_mirror_front_allowance(float widths, float camera_widths) {
    aurora::mirror::set_front_allowance(widths, camera_widths);
}

static_assert(sizeof(wwvr_visionos_mirror_vertex) == sizeof(aurora::mirror::Vertex));
static_assert(sizeof(wwvr_visionos_mirror_part) == sizeof(aurora::mirror::Part));
static_assert(offsetof(wwvr_visionos_mirror_part, wrap_s) == offsetof(aurora::mirror::Part, wrapS));

bool wwvr_visionos_mirror_acquire(wwvr_visionos_mirror_frame* frame, uint32_t up_to) {
    static std::vector<wwvr_visionos_mirror_texture> textures;
    aurora::mirror::Frame source;
    const bool ok = aurora::mirror::acquire(source, up_to);
    textures.clear();
    for (uint32_t i = 0; i < source.textureCount; ++i) {
        const auto& t = source.textures[i];
        textures.push_back({t.id, t.rgba, t.width, t.height, t.mipmapped, t.cutout});
    }
    *frame = {};
    frame->serial = source.serial;
    frame->game_frame = source.tag;
    frame->scene = source.scene;
    frame->vertices = reinterpret_cast<const wwvr_visionos_mirror_vertex*>(source.vertices);
    frame->vertex_count = source.vertexCount;
    frame->indices = source.indices;
    frame->index_count = source.indexCount;
    frame->parts = reinterpret_cast<const wwvr_visionos_mirror_part*>(source.parts);
    frame->part_count = source.partCount;
    std::copy(source.boundsMin, source.boundsMin + 3, frame->bounds_min);
    std::copy(source.boundsMax, source.boundsMax + 3, frame->bounds_max);
    frame->tan_half_x = source.tanHalfX;
    frame->tan_half_y = source.tanHalfY;
    frame->focus = source.focus;
    frame->plane = source.plane;
    // Its camera's aim (NaN if no longer kept: the window keeps the last), and whether the camera
    // cut since the last frame taken (in it or in one skipped); a gap longer than the frames kept
    // counts as a cut.
    static uint32_t lastTaken = 0xFFFFFFFFu;
    frame->pitch = std::numeric_limits<float>::quiet_NaN();
    if (ok) {
        std::lock_guard lock(g_mutex);
        const bool newer = source.tag != lastTaken;
        const uint32_t since = !newer ? 0 : lastTaken == 0xFFFFFFFFu ? 0xFFFFFFu : (source.tag - lastTaken) & 0xFFFFFFu;
        frame->cut = since > g_aims.size();
        for (const FrameAim& aim : g_aims) {
            const uint32_t back = (source.tag - aim.gameFrame) & 0xFFFFFFu;
            if (aim.gameFrame == source.tag) {
                frame->pitch = aim.pitch;
            }
            if (aim.gameFrame != 0xFFFFFFFFu && back < since && aim.cut) {
                frame->cut = true;
            }
        }
        lastTaken = source.tag;
    }
    frame->textures = textures.data();
    frame->texture_count = static_cast<uint32_t>(textures.size());
    frame->removed = source.removed;
    frame->removed_count = source.removedCount;
    return ok;
}

void wwvr_visionos_window_release(uint64_t serial) {
    std::lock_guard lock(g_mutex);
    for (Slot& slot : g_slots) {
        if (slot.state == SlotState::Reading && slot.serial == serial) {
            slot.state = SlotState::Free;
        }
    }
}

}  // extern "C"
