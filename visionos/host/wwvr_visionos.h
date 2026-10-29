#pragma once

// The bridge between the Apple Vision Pro app (SwiftUI, visionos/App) and the
// game. main() belongs to SwiftUI, so the game runs on a thread of its own,
// started once the immersive space's CompositorLayer exists. When the game is a
// framework these are the only symbols it exports (an exported_symbols_list),
// which also keeps the game's replacement operator new/delete out of the rest of
// the process. Every function is safe to call from the main thread.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The user's game file (disc image, ROM, data folder) in Documents, or NULL.
// Call before wwvr_visionos_start_game.
void wwvr_visionos_set_asset_path(const char* path);

// The cp_layer_renderer_t of the immersive space's CompositorLayer (Swift's
// LayerRenderer, passed unretained); the bridge retains it. NULL detaches it.
void wwvr_visionos_set_layer_renderer(void* layer_renderer);

// A spatial event of the immersive space (CompositorLayer onSpatialEvent):
// visionOS's look-and-pinch. `phase`: 0 active, 1 ended, 2 cancelled.
// `chirality`: 0 unknown, 1 left, 2 right. Ray and pose in the space's
// coordinates.
void wwvr_visionos_spatial_event(uint64_t event_id, int phase, int chirality, bool has_ray, float origin_x,
                              float origin_y, float origin_z, float direction_x, float direction_y,
                              float direction_z, bool has_pose, float pose_x, float pose_y, float pose_z);

// True once the layer renderer was invalidated (the immersive space closed).
bool wwvr_visionos_layer_invalidated(void);

// The Digital Crown pause. True once the game was seen in the space (its XR session reached
// FOCUSED): a space closed after that holds the game where it is, its clock and sound paused,
// until a new layer renderer arrives (wwvr_visionos_set_layer_renderer) or a quit. Never end the
// session on invalidation alone. False: closed before the game was seen; nothing to resume.
bool wwvr_visionos_can_resume(void);

// The progressive space's onWorldRecenter: a Digital Crown recenter moved the space's forward
// (and the portal) to where the wearer faces. The game turns its world to keep the view.
void wwvr_visionos_world_recentered(void);

// An audio interruption (Siri, a call, an alarm) began or ended: the game's sound (the AI engine,
// COSAISetPaused) and rumble pause, and in the window its clock too; Full and Progressive keep
// presenting frames.
void wwvr_visionos_set_audio_interrupted(bool interrupted);

// Which way the game's camera turns for the C stick (a gamepad's right stick, or the Sense
// controllers' as one gamepad in the window): left and right, and up and down, the other way from
// the GameCube's (the launcher's Controls tab). Before Play it's the game's start-up option
// (SwitchWaker's COS_CAMERA_INVERT_X/Y); while playing, the game takes it at its next camera read.
// Only the camera: the wind baton, the songs, the hookshot, the figure viewer and Full and
// Progressive's turning keep the stick's own directions.
void wwvr_visionos_set_camera_invert(bool invert_x, bool invert_y);

// Starts the game on its thread. False when it already ran in this process or
// the thread could not be created (see wwvr_visionos_last_error).
bool wwvr_visionos_start_game(void);
bool wwvr_visionos_game_running(void);

// The game's exit code once it returned; 0 before.
int wwvr_visionos_exit_code(void);

// Asks the game to quit the way closing its desktop window would. Nothing is saved: the game keeps
// what was saved from its own save menu. Lifts any pause so a waiting game thread sees the quit.
// Returns once the request is posted.
void wwvr_visionos_request_quit(void);

// The last error the bridge or the provider reported, or "".
const char* wwvr_visionos_last_error(void);

// Whether the room shows wherever the game's frames are transparent (the space
// opened mixed). The game then makes menus, loading and black screens
// see-through. Decided before the space opens; call before starting the game.
void wwvr_visionos_set_room_behind_menus(bool enabled);

// A mixed space has no visionOS movement boundary: with this on, the game fades
// into the room as the user walks away from where they started.
void wwvr_visionos_set_safety_boundary(bool enabled);

// Holds the game clock and sound (the headset came off, the window went to the
// background or was hidden, or closed where that pauses), or lets them run. Time
// spent held never reaches gameplay as one long frame: cap the frame delta.
void wwvr_visionos_set_paused(bool paused);

// --- Window mode: the game in a window in the shared space, beside other apps
// (GameWindowView.swift; host/window_frames.h). visionOS gives an app no head or
// controller tracking outside a Full Space, so the game plays flat, with its own
// camera and a gamepad.

// Call before wwvr_visionos_start_game, with no layer renderer.
void wwvr_visionos_set_window_mode(bool enabled);

// Once per window update (RealityKit's SceneEvents.Update): lets the game build its
// next frame. The window paces the game.
void wwvr_visionos_window_tick(void);

// One finished frame, as IOSurfaceRefs the game owns. Reads must wait for `event`
// (an MTLSharedEvent, or NULL when the game wrote them on the CPU) to reach
// `value`; the frame goes back with wwvr_visionos_window_release once they finish.
// A `generation` that changed means the surfaces are new ones.
typedef struct wwvr_visionos_window_frame {
    uint64_t serial;
    uint64_t generation;
    void* scene;     // BGRA8: the 3D scene before the HUD (screen effects included), or NULL
    void* distance;  // RGBA16F: depth along the view axis in .r (game units); with scene
    void* final;     // BGRA8: the finished frame, HUD and all
    void* ui;        // BGRA8, premultiplied: an overlay UI drawn outside the game's frame, or NULL
    void* base;      // BGRA8: the 3D scene before the screen effects (with the mirror), or NULL
    void* event;     // MTLSharedEvent, borrowed, or NULL
    uint64_t value;
    uint32_t game_frame;           // the game's frame number (24 bits), as the mirror's
    float tan_half_x, tan_half_y;  // the scene camera's half field of view, as tangents
    float focus;                   // the camera's distance to what it looks at (game units)
} wwvr_visionos_window_frame;

// The newest frame not yet taken, or false.
bool wwvr_visionos_window_acquire(wwvr_visionos_window_frame* frame);
void wwvr_visionos_window_release(uint64_t serial);

// --- The window's scene mirror (host/scene_mirror.h, MirrorScene.swift): the 3D
// scene's draws as triangles in the camera's view space (right-handed, -z ahead),
// for RealityKit to render from the viewer's real eyes. Each vertex carries the
// material as an affine function of its texture's sample T, in the game's gamma
// space: colour = T.rgb * mul.rgb + add.rgb, alpha = T.a * mul.a + add.a (mul and
// add half floats).
typedef struct wwvr_visionos_mirror_vertex {
    float position[3];
    float uv[2];
    uint16_t mul[4];
    uint16_t add[4];
} wwvr_visionos_mirror_vertex;

#define WWVR_VISIONOS_MIRROR_PART_OPAQUE 0u
#define WWVR_VISIONOS_MIRROR_PART_CUTOUT 1u
#define WWVR_VISIONOS_MIRROR_PART_BLEND 2u
#define WWVR_VISIONOS_MIRROR_CULL_BACK 1u
#define WWVR_VISIONOS_MIRROR_CULL_FRONT 2u
#define WWVR_VISIONOS_MIRROR_DEPTH_WRITE 4u
#define WWVR_VISIONOS_MIRROR_DEPTH_TEST 8u
#define WWVR_VISIONOS_MIRROR_BACKGROUND 16u
#define WWVR_VISIONOS_MIRROR_WRAP_CLAMP 0u
#define WWVR_VISIONOS_MIRROR_WRAP_REPEAT 1u
#define WWVR_VISIONOS_MIRROR_WRAP_MIRROR 2u

// A run of triangles with one material. Blends are premultiplied
// (colour + dst * (1 - opacity)): colour = rgb * (colour_base + colour_alpha * a),
// opacity = opacity_base + opacity_alpha * a + opacity_luma * luma(rgb).
typedef struct wwvr_visionos_mirror_part {
    uint32_t first_index, index_count;
    uint64_t texture;  // 0: none (white)
    uint32_t kind;     // WWVR_VISIONOS_MIRROR_PART_*
    uint32_t flags;
    float cutoff;
    float colour_base, colour_alpha, opacity_base, opacity_alpha, opacity_luma;
    uint8_t wrap_s, wrap_t;
    uint8_t pad[6];
} wwvr_visionos_mirror_part;

// A texture, sent once (again for new pixels): RGBA8, the top row first.
typedef struct wwvr_visionos_mirror_texture {
    uint64_t id;
    const uint8_t* rgba;
    uint32_t width, height;
    bool mipmapped, cutout;
} wwvr_visionos_mirror_texture;

typedef struct wwvr_visionos_mirror_frame {
    uint64_t serial;
    uint32_t game_frame;  // the game's frame number (24 bits), as the window frame's
    bool scene;           // false: no 3D scene this frame
    const wwvr_visionos_mirror_vertex* vertices;
    uint32_t vertex_count;
    const uint32_t* indices;
    uint32_t index_count;
    const wwvr_visionos_mirror_part* parts;
    uint32_t part_count;
    float bounds_min[3], bounds_max[3];
    float tan_half_x, tan_half_y, focus;
    // Where the window's glass goes (game units); what's nearer comes out in front of it,
    // within the front allowance.
    float plane;
    // How far the camera looks down (radians; up: negative): 0 in first person and in an event's
    // camera (a cutscene's); NaN if not known (the frame is older than the host's record of them).
    // The window turns its world more level by it (MirrorScene.place).
    float pitch;
    // The camera cut to somewhere else since the last frame taken, in it or in one skipped (the
    // turn follows at once, not eased).
    bool cut;
    const wwvr_visionos_mirror_texture* textures;  // new since the last acquire
    uint32_t texture_count;
    const uint64_t* removed;  // textures no longer used
    uint32_t removed_count;
} wwvr_visionos_mirror_frame;

// Whether the window wants the mirror. Turning it on sends every texture again.
void wwvr_visionos_set_mirror_enabled(bool enabled);
// The window's 2D/3D choice (WindowDepthToggle.swift), from the next frame: in 2D (false) the game
// hands over only its finished frame (scene, distance and base NULL, no HUD layer) and the mirror
// records nothing, but keeps its textures for 3D's return. 3D by default.
void wwvr_visionos_set_window_3d(bool three_d);
// How much wider than the 2D picture the game draws while the window shows 3D (the tangent of its
// half view, times this; 1 in 2D): the window lays the scene out as the picture is framed, and what
// the wider view adds lies past the picture's edges, for a viewer nearer than the camera's place or
// off to a side. From the next game frame.
void wwvr_visionos_set_window_view_scale(float scale);
// The window's re-aim (MirrorScene.place): how much of the camera's downward pitch it takes out,
// at most how much (radians), how far it raises the eye (a share of the camera's height above its
// focus), and how much more it turns (radians; test runs). The game works out where the window's
// foot meets the ground with them (the sill: the glass comes no farther). Call before the mirror's
// first frame.
void wwvr_visionos_set_window_aim(float fraction, float cap, float raise, float extra);
// How far in front of its glass the window lets the scene come out (window widths), and how far
// in front of it the window puts the camera (window widths; 0: where the view puts it, 1 / (2 tan),
// the scene in its own proportions, as MirrorScene.place lays it out).
void wwvr_visionos_set_mirror_front_allowance(float widths, float camera_widths);
// The newest frame no later than game frame `up_to` (the window frame shown with
// it, so the two match); its pointers last until the next call (main thread).
// False before the first.
bool wwvr_visionos_mirror_acquire(wwvr_visionos_mirror_frame* frame, uint32_t up_to);

#ifdef __cplusplus
}
#endif
