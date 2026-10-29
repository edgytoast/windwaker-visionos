// The real host behind the wwvr_visionos_* bridge, compiled INTO the game framework (not the
// app), with -fobjc-arc. From the plugin's template (port-build/templates/host/game_host.mm.tmpl)
// and the TPVR port's src/dusk/visionos/visionos_host.mm.
//
//   - SwiftUI owns main(). The game's main() is aurora_main (<aurora/main.h> renames it in
//     m_Do_main.cpp); it runs on a detached pthread with a 16 MB stack.
//   - SDL is told main already happened (SDL_SetMainReady) and runs its offscreen video driver
//     (visionos/patches/aurora/0101): the game thread never touches UIKit.
//   - The game reads its options from the environment (SwitchWaker's run harness: COS_DISC,
//     COS_USER_DIR, COS_*), so the bridge sets them before the game starts. Test hooks come from
//     WWVR_ARGS ("COS_KEY=value ..."), set by SIMCTL_CHILD_WWVR_ARGS on `xcrun simctl launch`.
//   - Quit = the game's own "window closed" path (an SDL quit event): the harness ends the
//     process with exit code 0.
//
// Full and Progressive: the immersive space's layer renderer, its spatial events and its end go to
// the vendored OpenXR provider (visionos/openxr-provider), which the game's OpenXR client
// (wwvr_xr.mm) drives from the game thread.

#include "wwvr_visionos.h"
#include "wwvr_window.h"
#include "wwvr_xr.h"

#include "vr/visionos/xr_visionos.h"

#include <aurora/aurora.h>
#include <aurora/main.h>

// cos_sdk/audio.h: its <dolphin/types.h> defines a BOOL that clashes with Objective-C's.
extern "C" void COSAISetPaused(bool paused);

// Only SDL_SetMainReady() is wanted from SDL_main.h; without SDL_MAIN_HANDLED it supplies a
// main() of its own.
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_init.h>
#include <SDL3/SDL_stdinc.h>
#define SDL_MAIN_HANDLED 1
#include <SDL3/SDL_main.h>

#import <Foundation/Foundation.h>

#include <pthread.h>
#include <sys/stat.h>

#include <atomic>
#include <cstdlib>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void* pool);

namespace {

constexpr size_t kGameThreadStackSize = 16 * 1024 * 1024;

std::mutex g_mutex;
std::string g_assetPath;
std::string g_lastError;
std::atomic_bool g_started{false};
std::atomic_bool g_running{false};
std::atomic_int g_exitCode{0};
std::atomic_bool g_roomBehindMenus{false};
std::atomic_bool g_paused{false};
std::atomic_bool g_audioInterrupted{false};
std::atomic_bool g_worldRecentered{false};
std::atomic_bool g_quitRequested{false};
std::atomic_bool g_sessionHeld{false};  // the game's OpenXR client holds it (wwvr_xr.mm)

// The pause from every source, applied together under one lock (main thread and game thread), so
// one source letting go never undoes another's pause:
//   - the app's (a hidden or background window, the Crown pause): clock and sound;
//   - the OpenXR client's hold (the space closed, the headset off): clock and sound;
//   - an audio interruption (Siri, a call): sound always, and the clock only in the window. In Full
//     and Progressive the game keeps presenting frames, as TPVR does: a space whose app stops
//     presenting shows its last frame with no safety boundary.
// The sound is the AI engine (the game's sound threads run from its DMA callback, on real time,
// not the game clock) and a gamepad's rumble, which SDL keeps up until told to stop.
std::mutex g_pauseMutex;
bool g_soundPaused = false;

void StopRumble() {
    if (SDL_WasInit(SDL_INIT_GAMEPAD) == 0) {
        return;
    }
    int count = 0;
    SDL_JoystickID* ids = SDL_GetGamepads(&count);
    int stopped = 0;
    for (int i = 0; i < count; ++i) {
        if (SDL_Gamepad* pad = SDL_GetGamepadFromID(ids[i]); pad != nullptr) {
            SDL_RumbleGamepad(pad, 0, 0, 0);
            ++stopped;
        }
    }
    SDL_free(ids);
    NSLog(@"[WWVR] pause: the rumble stopped on %d gamepad(s)", stopped);
}

void ApplyPause() {
    std::lock_guard lock(g_pauseMutex);
    const bool held = g_sessionHeld.load();
    const bool paused = g_paused.load();
    const bool interrupted = g_audioInterrupted.load();
    const bool clock = held || paused || (interrupted && !wwvr_xr_running());
    const bool sound = held || paused || interrupted;
    aurora_set_external_pause(clock);
    COSAISetPaused(sound);
    if (sound != g_soundPaused) {
        g_soundPaused = sound;
        if (sound) {
            StopRumble();
        }
        NSLog(@"[WWVR] pause: clock %s, sound %s (held %d, app %d, interrupted %d)", clock ? "held" : "running",
              sound ? "held" : "running", held, paused, interrupted);
    }
}

void SetError(std::string message) {
    NSLog(@"[WWVR] %s", message.c_str());
    std::lock_guard lock(g_mutex);
    g_lastError = std::move(message);
}

// The game's environment: the disc, where its settings, saves and caches live (Documents, so the
// player sees the saves in Files), and the test hooks' extra options.
void PrepareEnvironment(const std::string& disc) {
    NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    const std::string user = std::string(documents.UTF8String) + "/WindWaker";
    const std::string cache = std::string(caches.UTF8String) + "/aurora";
    mkdir(user.c_str(), 0755);
    mkdir(cache.c_str(), 0755);
    setenv("COS_USER_DIR", user.c_str(), 1);
    setenv("COS_CACHE_DIR", cache.c_str(), 1);
    // The options menu's file (pc_settings.cpp) would otherwise sit beside the executable, inside
    // the read-only app bundle.
    setenv("COS_SETTINGS", (user + "/settings.ini").c_str(), 1);
    // The forest mist at a lower resolution draws through an offscreen pass of its own, which
    // can't open inside a VR eye's pass (or under the scene mirror): drawn as on the GameCube.
    setenv("COS_MIST_LOWRES", "0", 0);
    if (!disc.empty()) {
        setenv("COS_DISC", disc.c_str(), 1);
    }
    // The launcher's camera directions (wwvr_visionos_set_camera_invert), before the test options.
    wwvr_window_camera_invert_to_env();
    // The game's log lines reach the unified log through NSLog; stderr is the harness's.
    if (const char* extra = std::getenv("WWVR_ARGS"); extra != nullptr) {
        std::istringstream tokens(extra);
        for (std::string token; tokens >> token;) {
            const size_t eq = token.find('=');
            if (eq != std::string::npos && eq > 0) {
                setenv(token.substr(0, eq).c_str(), token.substr(eq + 1).c_str(), 1);
                NSLog(@"[WWVR] option %s", token.c_str());
            }
        }
    }
}

void* GameThreadMain(void*) {
    pthread_setname_np("Wind Waker VR game");
    void* pool = objc_autoreleasePoolPush();
    std::string asset;
    {
        std::lock_guard lock(g_mutex);
        asset = g_assetPath;
    }
    PrepareEnvironment(asset);
    std::vector<std::string> args = {"WindWakerVision"};
    std::vector<char*> argv;
    for (std::string& arg : args) {
        argv.push_back(arg.data());
    }
    argv.push_back(nullptr);
    NSLog(@"[WWVR] game starting (window mode %d) with %s", wwvr_window_enabled() ? 1 : 0,
          asset.empty() ? "no disc" : asset.c_str());
    const int code = aurora_main(static_cast<int>(args.size()), argv.data());
    objc_autoreleasePoolPop(pool);
    g_exitCode.store(code);
    g_running.store(false);
    NSLog(@"[WWVR] game returned %d", code);
    return nullptr;
}

}  // namespace

extern "C" {

void wwvr_visionos_set_asset_path(const char* path) {
    std::lock_guard lock(g_mutex);
    g_assetPath = path != nullptr ? path : "";
}

void wwvr_visionos_set_layer_renderer(void* layer_renderer) {
    // The provider retains it; its session starts (or, after a Crown pause, resumes) with it.
    xr_visionos_set_layer_renderer(layer_renderer);
}

void wwvr_visionos_spatial_event(uint64_t event_id, int phase, int chirality, bool has_ray, float origin_x,
                                 float origin_y, float origin_z, float direction_x, float direction_y,
                                 float direction_z, bool has_pose, float pose_x, float pose_y, float pose_z) {
    // Look and pinch: the provider's pointer for bare hands.
    xr_visionos_spatial_event(event_id, phase, chirality, has_ray, origin_x, origin_y, origin_z, direction_x,
                              direction_y, direction_z, has_pose, pose_x, pose_y, pose_z);
}

bool wwvr_visionos_layer_invalidated(void) {
    return xr_visionos_layer_invalidated();
}

bool wwvr_visionos_can_resume(void) {
    return wwvr_xr_focused_once();
}

void wwvr_visionos_world_recentered(void) {
    g_worldRecentered.store(true);
}

void wwvr_visionos_set_audio_interrupted(bool interrupted) {
    g_audioInterrupted.store(interrupted);
    ApplyPause();
}

bool wwvr_visionos_start_game(void) {
    bool expected = false;
    if (!g_started.compare_exchange_strong(expected, true)) {
        SetError("The game already ran in this process; relaunch the app to play again.");
        return false;
    }
    SDL_SetMainReady();
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, kGameThreadStackSize);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    g_running.store(true);
    const int result = pthread_create(&thread, &attributes, &GameThreadMain, nullptr);
    pthread_attr_destroy(&attributes);
    if (result != 0) {
        g_running.store(false);
        SetError("Could not start the game thread (error " + std::to_string(result) + ").");
        return false;
    }
    return true;
}

bool wwvr_visionos_game_running(void) {
    return g_running.load();
}

int wwvr_visionos_exit_code(void) {
    return g_exitCode.load();
}

void wwvr_visionos_request_quit(void) {
    g_quitRequested.store(true);  // a game held for its space (wwvr_xr.mm) lets go
    // A pause (the Crown's, an audio interruption) stops the game's clock, and a game thread
    // waiting for its next tick then never wakes to see the quit: the clock runs again to let it.
    g_paused.store(false);
    g_audioInterrupted.store(false);
    ApplyPause();
    // A closed desktop window's quit event: the harness ends the process (pc_frame.cpp, exit 0).
    if (SDL_WasInit(SDL_INIT_EVENTS) != 0) {
        SDL_Event event{};
        event.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&event);
    }
}

void wwvr_visionos_set_room_behind_menus(bool enabled) {
    g_roomBehindMenus.store(enabled);
}

void wwvr_visionos_set_safety_boundary(bool enabled) {
    // Past about 1.2 m from where the game started, the world fades into the room.
    xr_visionos_set_safety_boundary(enabled);
}

const char* wwvr_visionos_last_error(void) {
    static thread_local std::string copy;
    {
        std::lock_guard lock(g_mutex);
        copy = g_lastError;
    }
    if (copy.empty()) {
        if (const char* provider = xr_visionos_last_error(); provider != nullptr) {
            copy = provider;
        }
    }
    return copy.c_str();
}

void wwvr_visionos_set_paused(bool paused) {
    g_paused.store(paused);
    ApplyPause();
}

}  // extern "C"

// Game -> host (not exported): the top of every iteration of the game's frame loop
// (pc_frame_begin). A plain pthread has no run loop to drain autorelease pools, so Metal objects
// made on the game thread would pile up (~4 MB/s in SHAR): drain one per frame.
extern "C" void wwvr_frame_boundary(void) {
    static void* pool = nullptr;
    if (pool != nullptr) {
        objc_autoreleasePoolPop(pool);
    }
    pool = objc_autoreleasePoolPush();
}

// Game -> bridge (not exported): read by the game's VR layer (visionos/game/wwvr_vr.cpp) to decide
// whether menus and black screens go see-through.
extern "C" bool wwvr_visionos_room_behind_menus_enabled(void) {
    return g_roomBehindMenus.load();
}

// Client -> bridge (not exported): the app asked the game to quit (wwvr_xr.mm stops holding).
extern "C" bool wwvr_visionos_quit_requested(void) {
    return g_quitRequested.load();
}

// Client -> bridge (not exported): the game's OpenXR client holds the game while its space is
// closed or hidden, and lets go (ApplyPause keeps any other pause).
extern "C" void wwvr_visionos_set_session_hold(bool held) {
    g_sessionHeld.store(held);
    ApplyPause();
}

// Client -> bridge (not exported): a Digital Crown recentre since the last frame (wwvr_xr.mm).
extern "C" bool wwvr_visionos_consume_world_recenter(void) {
    return g_worldRecentered.exchange(false);
}
