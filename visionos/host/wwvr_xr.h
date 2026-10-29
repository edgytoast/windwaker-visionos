#pragma once

// The game's OpenXR client on Apple Vision Pro: the session, its swapchains, frames and actions,
// over the vendored provider (visionos/openxr-provider: CompositorServices and ARKit). Host side
// (the framework's malloc allocator; visionos/cmake/framework.cmake): the game's VR hooks
// (visionos/game/wwvr_vr.cpp, inside the game's own object) reach it only through this C API, with
// plain data and Dawn texture handles.
//
// A frame, on the game thread:
//   wwvr_xr_begin_frame()   xrWaitFrame/xrBeginFrame, the eyes, the head, the hands and buttons;
//                           this frame's swapchain images are acquired
//   (the painter draws each eye into an offscreen pass and resolves it)
//   wwvr_xr_submit_eye()    an encoder task copies the eye into its swapchain image
//   wwvr_xr_submit_panel()  an encoder task turns the 2D drawn over black and over white into the
//                           panel's premultiplied image
//   wwvr_xr_finish_encoding()  the last task of the frame: Dawn's access ends after the submit
//   (aurora_end_frame)
//   wwvr_xr_end_frame()     waits for the render worker, hands the compositor the write fences,
//                           releases the images and ends the frame with its layers

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x, y, z, w;
} wwvr_xr_quat;

typedef struct {
    float x, y, z;
} wwvr_xr_vec3;

typedef struct {
    wwvr_xr_quat orientation;
    wwvr_xr_vec3 position;
} wwvr_xr_pose;

// Tangent angles in radians, OpenXR's XrFovf (left and down negative).
typedef struct {
    float left, right, up, down;
} wwvr_xr_fov;

enum { WWVR_XR_LEFT = 0, WWVR_XR_RIGHT = 1 };

// The hands, Sense controllers or bare hands (the provider answers Touch bindings from either).
typedef struct {
    bool tracked[2];        // grip and aim poses valid
    bool controller[2];     // a Sense half, not a bare hand
    wwvr_xr_pose grip[2];   // in the reference space
    wwvr_xr_pose aim[2];
    float trigger[2];       // 0..1
    float squeeze[2];       // 0..1
    float stick_x[2];       // -1..1, right
    float stick_y[2];       // -1..1, up
    bool primary[2];        // A (right) / X (left): Cross / Square, or the middle-finger pinch
    bool secondary[2];      // B (right) / Y (left): Circle / Triangle, or the ring-finger pinch
    bool stick_click[2];
    bool menu;              // the left menu button (Create), or the left little-finger pinch
} wwvr_xr_input;

typedef struct {
    bool render;            // draw the eyes this frame (the compositor wants a frame)
    uint32_t width, height; // an eye image's size in pixels
    wwvr_xr_pose head;      // the head (VIEW space) in the reference space
    wwvr_xr_pose eye[2];
    wwvr_xr_fov fov[2];
    wwvr_xr_input input;
    uint64_t frame;         // counts frames begun
    int64_t display_period_ns;  // the display's refresh period
    bool recentered;        // the world was recentered since the last frame (Digital Crown)
} wwvr_xr_frame;

// The app handed over an immersive space's layer (Full or Progressive) and it is still there.
bool wwvr_xr_wanted(void);
// The session is running and frames flow.
bool wwvr_xr_running(void);
// The session focused at least once (the Crown pause can resume).
bool wwvr_xr_focused_once(void);

// Game thread. Starts the session when wanted (once), handles its events, and begins a frame.
// False: no frame this time (no layer, the session is idle, or an error); nothing to end.
bool wwvr_xr_begin_frame(wwvr_xr_frame* frame);
// The eye's image this frame: `texture` is a WGPUTexture of the eye's size (a resolve snapshot,
// valid for this frame). Call after the eye's offscreen pass is resolved (never inside one).
void wwvr_xr_submit_eye(int eye, void* texture);
// The panel (HUD and menus): the 2D drawn over black and over white, `width` x `height`, shown as a
// quad of `width_m` metres placed by the client (wwvr_xr_set_panel_mode).
void wwvr_xr_submit_panel(void* over_black, void* over_white, uint32_t width, uint32_t height);
// Where the panel goes: 0 the HUD (a lazy-follow panel ahead and below), 1 a menu (nearer, straight
// ahead, recentred on the head when it opens).
void wwvr_xr_set_panel_mode(int mode);
// Last thing pushed in the frame: Dawn's access to the images ends after the frame is submitted.
void wwvr_xr_finish_encoding(void);
// Game thread, after aurora_end_frame: ends the frame begun by wwvr_xr_begin_frame.
void wwvr_xr_end_frame(void);

// The room around the game: `see_through` shows the room where the eyes are transparent (menus,
// black screens); `opacity` fades the eyes' picture (1 opaque, 0 the room or black).
void wwvr_xr_set_room(bool see_through, float opacity);
// A rumble on one hand.
void wwvr_xr_haptic(int hand, float amplitude, float seconds);
// The panel's image size (the 2D is drawn at this size).
void wwvr_xr_panel_size(uint32_t* width, uint32_t* height);

// The comfort options (the launcher's Advanced options, in the app's UserDefaults; re-read about
// once a second, so they change while the game runs).
typedef struct {
    bool snap_turn;          // the right stick turns in steps (else smoothly)
    float snap_degrees;      // a step
    float smooth_speed;      // degrees a second at full tilt
    bool sword_left;         // the sword in the left hand (the shield in the right)
} wwvr_xr_comfort;
void wwvr_xr_get_comfort(wwvr_xr_comfort* comfort);

#ifdef __cplusplus
}
#endif
