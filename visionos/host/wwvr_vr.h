#pragma once

// Wind Waker in VR on Apple Vision Pro: the game's hooks. Called from the game's units under
// COS_VISIONOS (m_Do_graphic.cpp's painter, d_camera.cpp's view, m_Do_main.cpp's loop,
// m_Do_controller_pad.cpp's pad read); implemented in visionos/game/wwvr_vr.cpp, inside the game's
// own object, over the OpenXR client (visionos/host/wwvr_xr.h). In the Window view and on a frame
// with no headset frame they all do nothing, and the game draws as before.
//
// The painter in VR, per frame:
//   wwvr_vr_frame_begin()            the headset's frame: eyes, head, hands
//   for each eye (wwvr_vr_eye_first/next):
//     wwvr_vr_eye_begin(eye)         an offscreen pass at the eye's size; the eye's projection in
//     ... the camera block ...       the view; the eye's offset from the head as the stereo transform
//     wwvr_vr_eye_end(eye)           the pass resolved and copied into the eye's image
//   for the panel's two passes (wwvr_vr_panel_first/next):
//     wwvr_vr_panel_begin(pass)      the 2D over black, then over white
//     ... the 2D ...
//     wwvr_vr_panel_end(pass)        both: the HUD and menus as a panel with its own transparency
//   (In the Window view the same two passes make the window's HUD layer on a frame with a 3D
//   scene: wwvr_window_hud_split.)
//   wwvr_vr_frame_finish()           end of the painter
// and after aurora_end_frame, wwvr_vr_frame_end().

#ifdef __cplusplus
extern "C" {
#endif

// The painter.
bool wwvr_vr_frame_begin(void);   // true: this frame draws for the headset
bool wwvr_vr_drawing(void);       // between frame_begin (true) and frame_finish
int wwvr_vr_eye_first(void);      // the first eye (0); flat: 0 once
int wwvr_vr_eye_next(int eye);    // the next eye, or -1
void wwvr_vr_eye_begin(int eye);
void wwvr_vr_eye_end(int eye);
bool wwvr_vr_eye_once(int eye);   // per-frame work inside the eye loop runs on this eye only
bool wwvr_vr_screen_effects(void); // motion blur and depth of field (off in VR: pictures of one view)
bool wwvr_vr_world_visible(void); // the 3D world is drawn this frame (not behind a menu over the room)
int wwvr_vr_panel_first(void);    // the 2D's first pass; flat: 0 once
int wwvr_vr_panel_next(int pass);
bool wwvr_vr_panels(void);        // the 2D goes to two passes this frame: VR's panel, or the
                                  // window's HUD layer (wwvr_window_hud_split)
void wwvr_vr_panel_begin(int pass);
void wwvr_vr_panel_end(int pass);
void wwvr_vr_frame_finish(void);
// The main loop, after aurora_end_frame.
void wwvr_vr_frame_end(void);

// The fade's step (mDoGph_gInf_c::calcFade) happens once a frame, on the eye this allows.
bool wwvr_vr_fade_steps(void);

// Repaints (the main loop, after a tick's frame): whether another display refresh fits before the
// next tick is due, and one (an Aurora frame around mDoGph_Repaint, the painter drawing the same
// lists from the head's newest pose). The game's ticks keep their own time either way.
bool wwvr_vr_repaint_due(void);
void wwvr_vr_repaint(void);

// The camera (d_camera.cpp): the head-tracked view replaces the game camera's in view_setup
// (wwvr_vr_camera) and camera_draw (wwvr_vr_camera_draw: the view the frame's draw lists are made
// with), before the view matrix is made. `view` is a view_class*.
void wwvr_vr_camera(void* view);
void wwvr_vr_camera_draw(void* view);
// The yaw the stick moves Link relative to (dCam_getControledAngleY): the head's in first person.
bool wwvr_vr_control_yaw(short* yaw);

// The player sees through Link's eyes (gameplay in Full and Progressive, not events): Link's own
// model isn't drawn (daPy_lk_c::draw, as in the game's first-person view).
bool wwvr_vr_first_person(void);
// A held item's model matrix (3x4, the game's Mtx) in the player's hand: role 0 the sword hand
// (the launcher's, right unless set), 1 the other. The model's extents (its root joint's bounds)
// say how it lies: a sword along the hand's forward, a shield (`shield`) facing forward. False
// when the hand isn't tracked or the player isn't in first person.
bool wwvr_vr_held_mtx(int role, const float model_min[3], const float model_max[3], int shield, float out[3][4]);

// The painter's display-heap swaps so far (m_Do_graphic.cpp): a block allocated from it since the
// last swap stays valid until the next but one, for every eye and repaint of the frame.
unsigned wwvr_paint_generation(void);

// The pads (mDoCPd_Read): the headset's controllers as port 0.
void wwvr_vr_pad_feed(void);

#ifdef __cplusplus
}
#endif
