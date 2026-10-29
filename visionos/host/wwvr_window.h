#pragma once

// The game in a window in the shared space (Immersion: Window): the hooks the game's painter
// (game/src/m_Do/m_Do_graphic.cpp, mDoGph_Painter) calls, under COS_VISIONOS. visionOS gives an
// app no head pose outside a Full Space, so the game plays flat (its own camera) and hands each
// frame to the app as images in IOSurfaces; with the scene mirror on (aurora/mirror.h, the
// visionos/patches/aurora/0102 patch) its 3D draws are recorded for the window to draw itself.
// Adapted from the TPVR port's src/dusk/visionos/visionos_window.hpp.
//
// Every function is a no-op unless window mode was set before the game started.

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Window mode for this run (the bridge sets it before the game starts).
bool wwvr_window_enabled(void);

// Top of the painter, once a frame: waits for the window's next display update (at most 100 ms,
// so a hidden window doesn't stop the game dead), numbers the frame and opens the mirror's frame.
void wwvr_window_begin_frame(void);

// The 3D camera rendered this frame (the painter's camera block): its projection's diagonal
// (mProjMtx[0][0], [1][1]), where it is and what it looks at, and its near and far planes.
void wwvr_window_note_scene(float proj00, float proj11, float eye_x, float eye_y, float eye_z, float center_x,
                            float center_y, float center_z, float near_z, float far_z);

// The 3D world is drawn and the screen effects (motion blur, depth of field) come next: the
// mirror's frame ends, and the picture so far is kept (Base).
void wwvr_window_scene_drawn(void);

// Whether this frame's 3D world is being mirrored (from begin_frame to scene_drawn).
bool wwvr_window_mirroring(void);

// The window's 3D draws wider than its picture (wwvr_visionos_set_window_view_scale; the window
// frames the picture at the game's own view). The scale is taken once a game frame, at the camera's
// view_setup; 1 in 2D and in first person (the picto box judges and keeps what was drawn, and a
// first-person view is framed to be looked through, not around).
void wwvr_window_take_view_scale(bool first_person);
// This frame's camera is an event's (a cutscene's, framed by the game): the window sends no pitch
// for its re-aim (MirrorScene.place), as in first person. Set at view_setup.
void wwvr_window_set_event_camera(bool event);
// The player (view_setup; false: none): his feet and his eyes' height, for the window's near field
// (note_scene, aurora 0111): how near the camera he comes, and the ground he stands on, where the
// window's foot meets it (the sill).
void wwvr_window_set_player(bool present, float x, float y, float z, float eye_y);
// The launcher's camera directions (wwvr_visionos_set_camera_invert), on the game thread: into the
// environment before the game starts (PrepareEnvironment; WWVR_ARGS's test options come after and
// win), and a change while playing into SwitchWaker's options at the camera's C-stick read
// (d_camera.cpp's dCamera_cStickX).
void wwvr_window_camera_invert_to_env(void);
void wwvr_window_sync_camera_invert(void);
// The camera's vertical view angle (degrees) the game draws and culls with (d_camera.cpp's
// view_setup and camera_draw): the game's own, widened by that scale. `projection`: the game's
// projection is made with it (camera_draw).
float wwvr_window_fovy(float fovy, bool projection);
// How much wider than its picture the game's projection was made (1 but in the window's 3D):
// mDoLib_project gives places in the picture, as the HUD laid over it and the game's own checks
// (the camera's pointInSight, the message box's side, the enemy's health bar) expect, and a depth
// peek at such a place is made at the drawn frame's (d_drawlist.cpp).
float wwvr_window_projection_scale(void);

// The painter's two stages around the 2D: the scene and its depth before the HUD, then the
// finished frame.
void wwvr_window_before_hud(void);
void wwvr_window_after_hud(void);

// The HUD's own layer. On a frame with a 3D scene the 2D isn't drawn over it: it's drawn twice
// into passes of the frame's size, over black (pass 0) and over white (pass 1), which give each
// pixel's exact cover and colour whatever blending the game used, and the window lays that over
// its own 3D. (Worked out from the finished frame instead, a translucent panel kept a picture of the
// game's flat 3D under it, which showed through the HUD over the mirror's.) The painter's panel
// loop (wwvr_vr_panel_*) calls these; hud_split says whether this frame does it.
bool wwvr_window_hud_split(void);
bool wwvr_window_hud_begin(int pass);  // true: the pass is open (to be filled over black or white)
void wwvr_window_hud_end(int pass);

#ifdef __cplusplus
}
#endif
