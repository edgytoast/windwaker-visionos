// Wind Waker in VR on Apple Vision Pro: the game's hooks (visionos/host/wwvr_vr.h). Inside the
// game's own object (visionos/cmake/framework.cmake), so it reads the game's state directly; it
// allocates nothing (no std containers: here operator new is the game's heap). The headset itself
// is the OpenXR client's (visionos/host/wwvr_xr.h).
//
// The view. The game's draw lists are built once a frame (the actors' draw, after the camera's
// draw) from a centre view: the head-tracked first-person view at the head pose of the frame
// before. The painter then draws them once per eye, into that eye's pass, with
//   - the eye's own asymmetric projection in place of the camera's, and
//   - the stereo transform T = V_eye * V_centre^-1 applied after the modelview (Aurora's
//     GX_AURORA_SET_EYE_TRANSFORM, perspective draws only),
// so each eye sees the scene from where it is now (the head's motion since the lists were built
// included) with no second pass over the actors.
//
// The world. A pose p in the OpenXR LOCAL space is placed in the game's world as
//   world = anchor + Ry(base) * (p - ref) * kUnitsPerMetre
// anchor: Link's eye (gameplay) or the game camera's eye (events and cutscenes); ref: the head's
// position at the last recentre; base: the yaw that turns the player's forward at the recentre
// onto Link's facing (gameplay, plus the turns the right stick made) or onto the camera's
// (events). Ry(a) turns the game's way: +Z to (sin a, 0, cos a).

#include "wwvr_vr.h"

#include "wwvr_visionos.h"
#include "wwvr_window.h"
#include "wwvr_xr.h"

#include "JSystem/J3DGraphBase/J3DShape.h"
#include "JSystem/J3DGraphBase/J3DSys.h"
#include "JSystem/JFramework/JFWDisplay.h"
#include "JSystem/JKernel/JKRHeap.h"
#include "JSystem/JUtility/JUTFader.h"
#include "d/d_com_inf_game.h"
#include "d/d_demo.h"
#include "d/d_item.h"
#include "d/d_meter.h"
#include "f_op/f_op_view.h"
#include "m_Do/m_Do_controller_pad.h"
#include "m_Do/m_Do_graphic.h"

#include <aurora/aurora.h>
#include <aurora/gfx.hpp>
#include <dolphin/gx.h>
#include <dolphin/gx/GXAuroraStereo.h>
#include <dolphin/mtx.h>
#include <dolphin/pad.h>

#include <TargetConditionals.h>
#include <math.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern "C" bool wwvr_visionos_room_behind_menus_enabled(void);  // game_host.mm
extern "C" void wwvr_frame_boundary(void);                       // game_host.mm
void mDoGph_Repaint();                                           // m_Do_graphic.cpp
int mDoGph_faderAlphaThisFrame();                                // m_Do_graphic.cpp

namespace {

// Game units per metre of the player's movement and eye separation. Wind Waker's world is about a
// unit to the centimetre (Link, a child, stands about 1.2 m); this keeps the player at Link's size.
constexpr float kUnitsPerMetre = 100.0f;
// Link's eye above his feet when his own (bobbing) eye can't be used.
constexpr float kDefaultEyeHeight = 105.0f;
constexpr float kPi = 3.14159265358979f;
constexpr float kS16PerRadian = 32768.0f / kPi;

// The headset's frame, from frame_begin on.
wwvr_xr_frame g_frame;
bool g_frameOpen = false;   // an XR frame was begun this paint (ended in frame_end)
bool g_drawing = false;     // this paint draws for the headset
bool g_worldVisible = true;
bool g_haveHead = false;    // a head pose has been seen
bool g_menuOverRoom = false;

// The world placement (see the top).
float g_ref[3] = {0, 0, 0};
float g_forwardRef = 0;     // the head's LOCAL yaw at the recentre (radians, about +Y, 0 = -Z)
float g_turn = 0;           // gameplay base yaw (radians): Link's facing at the recentre, plus turns
bool g_placed = false;      // g_ref, g_forwardRef and g_turn are set
float g_eyeHeight = kDefaultEyeHeight;

// The centre view the draw lists are built with (camera_draw), the base and anchor it used, and
// when. Between ticks (repaints), gameplay's view keeps turning with the stick and moving with
// Link at his last speed, from there.
Mtx g_centreView;
bool g_centreValid = false;
float g_viewBase = 0;
float g_viewAnchor[3] = {0, 0, 0};
bool g_viewCameraLeads = true;
double g_viewTime = 0;
float g_anchorVelocity[3] = {0, 0, 0};  // units a second
bool g_repainting = false;
double g_tickStart = 0;
int g_repaints = 0;
bool g_wasLeading = true;

// The eye being drawn.
int g_eye = -1;
Mtx44 g_savedProj;
view_class* g_eyeView = nullptr;

// The panel's two passes.
aurora::gfx::ResolvedTargets g_panelTargets[2];

// The right stick's turns.
bool g_turnArmed = true;
double g_lastTurnTime = 0;

void Log(const char* format, ...) __attribute__((format(printf, 1, 2)));
void Log(const char* format, ...) {
    char line[512];
    va_list args;
    va_start(args, format);
    const int n = vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (n > 0) {
        write(STDERR_FILENO, line, strnlen(line, sizeof(line)));
    }
}

// --- math ---

// Row-major rotation of a unit quaternion (columns: the pose's axes in the reference space).
void QuatToMtx(const wwvr_xr_quat& q, float r[3][3]) {
    const float xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
    const float xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
    const float wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
    r[0][0] = 1 - 2 * (yy + zz); r[0][1] = 2 * (xy - wz);     r[0][2] = 2 * (xz + wy);
    r[1][0] = 2 * (xy + wz);     r[1][1] = 1 - 2 * (xx + zz); r[1][2] = 2 * (yz - wx);
    r[2][0] = 2 * (xz - wy);     r[2][1] = 2 * (yz + wx);     r[2][2] = 1 - 2 * (xx + yy);
}

// The game's yaw rotation: +Z to (sin a, 0, cos a).
void YawMtx(float a, float r[3][3]) {
    const float s = sinf(a), c = cosf(a);
    r[0][0] = c;  r[0][1] = 0; r[0][2] = s;
    r[1][0] = 0;  r[1][1] = 1; r[1][2] = 0;
    r[2][0] = -s; r[2][1] = 0; r[2][2] = c;
}

void Mul33(const float a[3][3], const float b[3][3], float out[3][3]) {
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
}

// The LOCAL yaw of a pose's forward (-Z): radians about +Y, 0 looking down -Z.
float LocalYaw(const wwvr_xr_quat& q) {
    const float fx = -2.f * (q.x * q.z + q.w * q.y);
    const float fz = -(1.f - 2.f * (q.x * q.x + q.y * q.y));
    return atan2f(-fx, -fz);
}

float Wrap(float a) {
    while (a > kPi) a -= 2 * kPi;
    while (a < -kPi) a += 2 * kPi;
    return a;
}

// A LOCAL pose placed in the world (see the top): its position and its axes.
void PlacePose(const wwvr_xr_pose& pose, float base, const float anchor[3], float pos[3], float rot[3][3]) {
    float ry[3][3];
    YawMtx(base, ry);
    // LOCAL and the game's world are both right-handed and Y-up; a LOCAL turn by +a about +Y is a
    // game turn by +a (its yaw is atan2(x, z) of the facing, LOCAL's facing at yaw 0 is -Z, i.e. a
    // game yaw of pi): so the game yaw of a LOCAL direction is its LOCAL yaw + pi, and Ry(base)
    // adds base to it.
    const float d[3] = {(pose.position.x - g_ref[0]) * kUnitsPerMetre, (pose.position.y - g_ref[1]) * kUnitsPerMetre,
                        (pose.position.z - g_ref[2]) * kUnitsPerMetre};
    for (int i = 0; i < 3; ++i) {
        pos[i] = anchor[i] + ry[i][0] * d[0] + ry[i][1] * d[1] + ry[i][2] * d[2];
    }
    float q[3][3];
    QuatToMtx(pose.orientation, q);
    Mul33(ry, q, rot);
}

// The view matrix (world to eye) of a placed pose.
void ViewOf(const float pos[3], const float rot[3][3], Mtx out) {
    for (int i = 0; i < 3; ++i) {
        out[i][0] = rot[0][i];
        out[i][1] = rot[1][i];
        out[i][2] = rot[2][i];
        out[i][3] = -(rot[0][i] * pos[0] + rot[1][i] * pos[1] + rot[2][i] * pos[2]);
    }
}

// GX's perspective matrix for an asymmetric field of view (TPVR's eyeFovToProjMtx).
void FovToProj(const wwvr_xr_fov& fov, float nearZ, float farZ, Mtx44 out) {
    const float tl = tanf(fov.left), tr = tanf(fov.right), td = tanf(fov.down), tu = tanf(fov.up);
    const float rw = 1.f / (tr - tl), rh = 1.f / (tu - td);
    memset(out, 0, sizeof(Mtx44));
    out[0][0] = 2.f * rw;
    out[0][2] = (tr + tl) * rw;
    out[1][1] = 2.f * rh;
    out[1][2] = (tu + td) * rh;
    const float depth = 1.f / (farZ - nearZ);
    out[2][2] = -nearZ * depth;
    out[2][3] = -(farZ * nearZ) * depth;
    out[3][2] = -1.f;
}

double Seconds() {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec * 1e-9;
}

// --- the game's state ---

fopAc_ac_c* Player() {
    return dComIfGp_getPlayer(0);
}

// Events, cutscenes and demo cameras: the game camera keeps the view (its position, its heading).
bool CameraLeads() {
    if (Player() == NULL || dComIfGp_event_runCheck()) {
        return true;
    }
    // The demo manager exists only once a scene does.
    dDemo_manager_c* demo = dComIfGp_demo_get();
    return demo != NULL && demo->getObject() != NULL && demo->getObject()->getActiveCamera() != NULL;
}

// The anchor and the base yaw for this frame's view; `view` holds the game camera's own look-at.
// The game camera's own look-at: what the view holds before we override it (camera_execute's
// store() writes it each tick, then view_setup and camera_draw both override it). A view still
// holding our override (store() supplied nothing new, or camera_draw after view_setup) keeps the
// copy from before.
float g_gameEye[3] = {0, 0, 0};
float g_gameCenter[3] = {0, 0, -1};
float g_writtenEye[3] = {0, 0, 0};
float g_writtenCenter[3] = {0, 0, 0};
bool g_written = false;

void NoteGameLook(const view_class* view) {
    const cXyz& e = view->mLookat.mEye;
    const cXyz& c = view->mLookat.mCenter;
    const bool ours = g_written && e.x == g_writtenEye[0] && e.y == g_writtenEye[1] && e.z == g_writtenEye[2] &&
                      c.x == g_writtenCenter[0] && c.y == g_writtenCenter[1] && c.z == g_writtenCenter[2];
    if (!ours) {
        g_gameEye[0] = e.x;
        g_gameEye[1] = e.y;
        g_gameEye[2] = e.z;
        g_gameCenter[0] = c.x;
        g_gameCenter[1] = c.y;
        g_gameCenter[2] = c.z;
    }
}

void AnchorAndBase(const view_class* view, float anchor[3], float* base) {
    (void)view;
    fopAc_ac_c* player = Player();
    if (CameraLeads()) {
        anchor[0] = g_gameEye[0];
        anchor[1] = g_gameEye[1];
        anchor[2] = g_gameEye[2];
        const float dx = g_gameCenter[0] - g_gameEye[0];
        const float dz = g_gameCenter[2] - g_gameEye[2];
        const float cameraYaw = atan2f(dx, dz);
        // The player's forward (at the recentre) looks where the camera looks.
        *base = Wrap(cameraYaw - (g_forwardRef + kPi));
        return;
    }
    // Link's eye: his feet, at his eye's height, smoothed (his own eye bobs as he walks).
    const float eye = player->eyePos.y - player->current.pos.y;
    if (eye > 20.0f && eye < 250.0f) {
        g_eyeHeight += (eye - g_eyeHeight) * 0.1f;
    }
    anchor[0] = player->current.pos.x;
    anchor[1] = player->current.pos.y + g_eyeHeight;
    anchor[2] = player->current.pos.z;
    *base = g_turn;
}

// A recentre after the first placement (the Digital Crown held: visionOS moved the space's origin
// to the head): the view stays where it was, the space under it moves. `previousYaw` is the
// head's LOCAL yaw just before.
void KeepViewAcrossRecentre(float previousYaw) {
    const wwvr_xr_pose& head = g_frame.head;
    const float yaw = LocalYaw(head.orientation);
    g_turn = Wrap(g_turn + previousYaw - yaw);
    g_forwardRef = Wrap(g_forwardRef + yaw - previousYaw);
    g_ref[0] = head.position.x;
    g_ref[1] = head.position.y;
    g_ref[2] = head.position.z;
    Log("[WWVR] vr: recentred, the view kept\n");
}

void Recentre() {
    const wwvr_xr_pose& head = g_frame.head;
    g_ref[0] = head.position.x;
    g_ref[1] = head.position.y;
    g_ref[2] = head.position.z;
    g_forwardRef = LocalYaw(head.orientation);
    float facing = 0;
    if (fopAc_ac_c* player = Player()) {
        facing = player->shape_angle.y / kS16PerRadian;
    }
    // Forward at the recentre is Link's facing.
    g_turn = Wrap(facing - (g_forwardRef + kPi));
    g_placed = true;
    Log("[WWVR] vr: recentred, Link facing %.0f deg, eye height %.0f units\n", facing * 180 / kPi, g_eyeHeight);
}

// The right stick turns the player: smoothly, or in steps (the launcher's comfort options).
// Right turns clockwise seen from above, a negative turn about +Y.
void Turn() {
    wwvr_xr_comfort comfort;
    wwvr_xr_get_comfort(&comfort);
    // The right stick, or a gamepad's (its C stick, as the game read it last tick).
    float x = g_frame.input.stick_x[WWVR_XR_RIGHT];
    if (fabsf(x) < 0.2f) {
        x = g_mDoCPd_cpadInfo[0].mCStickPosX;
    }
    const double now = Seconds();
    const float dt = g_lastTurnTime > 0 ? static_cast<float>(fmin(now - g_lastTurnTime, 0.1)) : 0.0f;
    g_lastTurnTime = now;
    if (comfort.snap_turn) {
        const float step = comfort.snap_degrees * kPi / 180.0f;
        if (g_turnArmed && fabsf(x) > 0.7f) {
            g_turn = Wrap(g_turn - (x > 0 ? step : -step));
            g_turnArmed = false;
        } else if (fabsf(x) < 0.3f) {
            g_turnArmed = true;
        }
        return;
    }
    const float dead = 0.2f;
    if (fabsf(x) > dead) {
        const float tilt = (fabsf(x) - dead) / (1.0f - dead);
        g_turn = Wrap(g_turn - copysignf(tilt, x) * comfort.smooth_speed * kPi / 180.0f * dt);
    }
}


// --- the hands: TPVR's swing detector (src/dusk/vr/vr_swing_detector.hpp), the sword hand ---

// A swing of the sword hand: fast enough, far enough, once until it slows or turns back.
struct SwingDetector {
    float triggerSpeed = 2.5f;       // m/s to fire
    float resetSpeed = 0.8f;         // m/s to fire again
    float minSwingDistance = 0.15f;  // m: a fast flick isn't a swing
    double cooldown = 0.12;          // s between swings
    float maxPlausibleSpeed = 15.0f; // m/s: a tracking jump isn't a swing
    bool hasPrev = false, inWindow = false, canFire = true, hasLastFire = false;
    float prev[3] = {0, 0, 0}, windowStart[3] = {0, 0, 0}, lastFire[3] = {0, 0, 0};
    double prevTime = 0, lastTrigger = -1000;

    bool Update(const float p[3], double t) {
        if (!hasPrev) {
            memcpy(prev, p, sizeof(prev));
            prevTime = t;
            hasPrev = true;
            return false;
        }
        const double dt = t - prevTime;
        if (dt <= 0) {
            return false;
        }
        const float d[3] = {p[0] - prev[0], p[1] - prev[1], p[2] - prev[2]};
        const float dist = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        const float speed = static_cast<float>(dist / dt);
        if (speed > resetSpeed) {
            if (!inWindow) {
                inWindow = true;
                memcpy(windowStart, prev, sizeof(windowStart));
            }
        } else {
            inWindow = false;
        }
        float windowDist = 0;
        if (inWindow) {
            const float w[3] = {p[0] - windowStart[0], p[1] - windowStart[1], p[2] - windowStart[2]};
            windowDist = sqrtf(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]);
        }
        bool fired = false;
        if (speed >= triggerSpeed && speed <= maxPlausibleSpeed && windowDist >= minSwingDistance &&
            t - lastTrigger >= cooldown && canFire) {
            fired = true;
            lastTrigger = t;
            canFire = false;
            memcpy(lastFire, d, sizeof(lastFire));
            hasLastFire = true;
        }
        if (speed <= resetSpeed) {
            canFire = true;
        }
        if (!canFire && hasLastFire && dist > 0 && d[0] * lastFire[0] + d[1] * lastFire[1] + d[2] * lastFire[2] < 0) {
            canFire = true;  // swung back the other way
        }
        memcpy(prev, p, sizeof(prev));
        prevTime = t;
        return fired;
    }
};

SwingDetector g_swing;
int g_swingTicks = 0;      // B held for the game this many more ticks (a swing)
bool g_swordLeft = false;  // the launcher's sword hand

int SwordHand() {
    return g_swordLeft ? WWVR_XR_LEFT : WWVR_XR_RIGHT;
}

// The sword hand's swings, from each frame's hand pose (LOCAL metres).
void Swings() {
    wwvr_xr_comfort comfort;
    wwvr_xr_get_comfort(&comfort);
    if (comfort.sword_left != g_swordLeft) {
        g_swordLeft = comfort.sword_left;
        g_swing = SwingDetector{};
    }
    const int hand = SwordHand();
    if (!g_frame.input.tracked[hand]) {
        g_swing.hasPrev = false;
        return;
    }
    const float p[3] = {g_frame.input.grip[hand].position.x, g_frame.input.grip[hand].position.y,
                        g_frame.input.grip[hand].position.z};
    if (g_swing.Update(p, Seconds()) && !CameraLeads() && !dMenu_flag()) {
        g_swingTicks = 2;
        wwvr_xr_haptic(hand, 0.45f, 0.06f);
        Log("[WWVR] vr: sword swing (%s hand)\n", hand == WWVR_XR_LEFT ? "left" : "right");
    }
}

// Fills the open pass with `colour` (an eye's at the game's back colour, the 2D's passes black or
// white), then gives the game's draws J3D's GX state and vertex formats back.
void FillPass(const GXColor& colour) {
    Mtx44 ortho;
    C_MTXOrtho(ortho, 0.0f, 480.0f, 0.0f, 640.0f, 0.0f, 10.0f);
    GXSetProjection(ortho, GX_ORTHOGRAPHIC);
    GXSetViewport(0.0f, 0.0f, 640.0f, 480.0f, 0.0f, 1.0f);
    GXSetScissor(0, 0, 640, 480);
    Mtx identity;
    MTXIdentity(identity);
    GXLoadPosMtxImm(identity, GX_PNMTX0);
    GXSetCurrentMtx(GX_PNMTX0);
    GXClearVtxDesc();
    GXSetVtxDesc(GX_VA_POS, GX_DIRECT);
    GXSetVtxAttrFmt(GX_VTXFMT0, GX_VA_POS, GX_POS_XYZ, GX_F32, 0);
    GXSetNumChans(1);
    GXSetChanCtrl(GX_COLOR0A0, GX_FALSE, GX_SRC_REG, GX_SRC_REG, 0, GX_DF_NONE, GX_AF_NONE);
    GXSetChanMatColor(GX_COLOR0A0, colour);
    GXSetNumTexGens(0);
    GXSetNumTevStages(1);
    GXSetNumIndStages(0);
    GXSetTevOrder(GX_TEVSTAGE0, GX_TEXCOORD_NULL, GX_TEXMAP_NULL, GX_COLOR0A0);
    GXSetTevOp(GX_TEVSTAGE0, GX_PASSCLR);
    GXSetBlendMode(GX_BM_NONE, GX_BL_ONE, GX_BL_ZERO, GX_LO_CLEAR);
    GXSetZMode(GX_FALSE, GX_ALWAYS, GX_FALSE);
    GXSetAlphaCompare(GX_ALWAYS, 0, GX_AOP_OR, GX_ALWAYS, 0);
    GXSetCullMode(GX_CULL_NONE);
    GXSetColorUpdate(GX_TRUE);
    GXSetFog(GX_FOG_NONE, 0, 0, 0, 0, colour);
    GXBegin(GX_QUADS, GX_VTXFMT0, 4);
    GXPosition3f32(0.0f, 0.0f, -5.0f);
    GXPosition3f32(640.0f, 0.0f, -5.0f);
    GXPosition3f32(640.0f, 480.0f, -5.0f);
    GXPosition3f32(0.0f, 480.0f, -5.0f);
    GXEnd();
    // The game's draws expect J3D's GX state and vertex formats, not the quad's.
    j3dSys.reinitGX();
    J3DShape::resetVcdVatCache();
}

// The 2D's two passes, over black then over white: the headset's panel in VR, the window's HUD
// layer on a Window frame with a 3D scene (wwvr_window_hud_split).
bool Panels() {
    return g_drawing || wwvr_window_hud_split();
}

}  // namespace

namespace {
bool OverrideView(view_class* view, float anchor[3], float* base, float pos[3], float rot[3][3]) {
    if (view == NULL || !g_haveHead || !g_placed || wwvr_window_enabled() || !wwvr_xr_running()) {
        return false;
    }
    NoteGameLook(view);
    AnchorAndBase(view, anchor, base);
    PlacePose(g_frame.head, *base, anchor, pos, rot);
    // The head's view as a look-at (the game makes its matrix from it): forward is -Z, up +Y.
    view->mLookat.mEye.set(pos[0], pos[1], pos[2]);
    view->mLookat.mCenter.set(pos[0] - rot[0][2] * 100.0f, pos[1] - rot[1][2] * 100.0f, pos[2] - rot[2][2] * 100.0f);
    g_writtenEye[0] = view->mLookat.mEye.x;
    g_writtenEye[1] = view->mLookat.mEye.y;
    g_writtenEye[2] = view->mLookat.mEye.z;
    g_writtenCenter[0] = view->mLookat.mCenter.x;
    g_writtenCenter[1] = view->mLookat.mCenter.y;
    g_writtenCenter[2] = view->mLookat.mCenter.z;
    g_written = true;
    view->mLookat.mUp.set(rot[0][1], rot[1][1], rot[2][1]);
    view->mBank = 0;
    // A field of view taking in both eyes (the actors' culling and the particles' billboards).
    float halfH = 0, halfV = 0;
    for (int i = 0; i < 2; ++i) {
        halfH = fmaxf(halfH, fmaxf(fabsf(tanf(g_frame.fov[i].left)), fabsf(tanf(g_frame.fov[i].right))));
        halfV = fmaxf(halfV, fmaxf(fabsf(tanf(g_frame.fov[i].up)), fabsf(tanf(g_frame.fov[i].down))));
    }
    if (halfH > 0 && halfV > 0) {
        // With room for the head's and the stick's turn until the next tick's lists (repaints draw
        // these lists turned up to ~45 ms on).
        view->mFovy = 2.0f * atanf(halfV * 1.4f) * 180.0f / kPi;
        view->mAspect = halfH / halfV;
    }
    if (view->mNear > 10.0f) {
        view->mNear = 10.0f;  // Link's hands and sword are close to the eyes
    }
    return true;
}
}  // namespace

extern "C" {

bool wwvr_vr_frame_begin(void) {
#if TARGET_OS_SIMULATOR
    // Test runs: WWVR_TEST_TIME=<hour> sets the time of day once the player is in a stage (the
    // lighting comparisons: dusk, night).
    static const char* s_testTime = getenv("WWVR_TEST_TIME");
    if (s_testTime != NULL && Player() != NULL) {
        const float hour = static_cast<float>(atof(s_testTime));
        dComIfGs_setTime(hour * 15.0f);
        Log("[WWVR] test: time set to %.1f h\n", hour);
        s_testTime = NULL;
    }
#endif
    g_drawing = false;
    g_frameOpen = false;
    if (!g_repainting) {
        // The tick's own frame: its repaints count from here.
        g_tickStart = Seconds();
        g_repaints = 0;
    }
    if (wwvr_window_enabled()) {
        return false;
    }
    // The headset's work runs on the host's allocator (Aurora and Dawn are host code anyway). A
    // frame with nothing to draw keeps the last head, eyes and hands (the client leaves them).
    const float previousYaw = g_haveHead ? LocalYaw(g_frame.head.orientation) : 0.0f;
    if (!wwvr_xr_begin_frame(&g_frame)) {
        return false;
    }
    g_frameOpen = true;
    if (!g_frame.render) {
        return false;
    }
    g_haveHead = true;
    if (!g_placed) {
        Recentre();
    } else if (g_frame.recentered) {
        KeepViewAcrossRecentre(previousYaw);
    }
    const bool leads = CameraLeads();
    if (!leads) {
        if (g_wasLeading) {
            // Out of an event or a cutscene (or into the first gameplay): the way the player looks
            // now is Link's facing.
            float facing = 0;
            if (fopAc_ac_c* player = Player()) {
                facing = player->shape_angle.y / kS16PerRadian;
            }
            g_turn = Wrap(facing - (LocalYaw(g_frame.head.orientation) + kPi));
        }
        Turn();
    }
    Swings();
    g_wasLeading = leads;
#if TARGET_OS_SIMULATOR
    // Test runs: WWVR_TEST_SWORD=1 gives Link the sword and shield once he's free to move (the
    // boot presets start before he has them).
    static bool s_armed = getenv("WWVR_TEST_SWORD") != NULL;
    if (s_armed && !leads) {
        s_armed = false;
        execItemGet(dItemNo_SWORD_e);
        execItemGet(dItemNo_SHIELD_e);
        Log("[WWVR] vr: test: the sword and shield given\n");
    }
#endif
    // A menu over the room: the room behind it instead of the world.
    g_menuOverRoom = wwvr_visionos_room_behind_menus_enabled() && dMenu_flag();
    g_worldVisible = !g_menuOverRoom;
    wwvr_xr_set_panel_mode(dMenu_flag() ? 1 : 0);
    // Fades: with the room behind menus they open onto the room, else they stay the game's black.
    float opacity = 1.0f;
    if (wwvr_visionos_room_behind_menus_enabled()) {
        // The painter's fade and the scene fade (JFWDisplay's fader: doors, loading zones).
        const GXColor& fade = mDoGph_gInf_c::getFadeColor();
        if (fade.r < 40 && fade.g < 40 && fade.b < 40) {
            opacity = 1.0f - fade.a / 255.0f;
        }
        // (The alpha it draws this frame: its colour stays opaque while it waits faded in.)
        if (JUTFader* fader = JFWDisplay::getManager()->getFader()) {
            const JUtility::TColor& c = fader->mColor;
            if (c.r < 40 && c.g < 40 && c.b < 40) {
                opacity = fminf(opacity, 1.0f - mDoGph_faderAlphaThisFrame() / 255.0f);
            }
        }
    }
    wwvr_xr_set_room(wwvr_visionos_room_behind_menus_enabled(), opacity);
    // The panel draws from now on; the eyes once the camera has made a head-tracked view.
    g_drawing = true;
    static unsigned s_ticks = 0;
    if (!g_repainting && ++s_ticks % 150 == 1) {
        fopAc_ac_c* player = Player();
        const GXColor& fade = mDoGph_gInf_c::getFadeColor();
        Log("[WWVR] vr: tick %u: %s, menu %d, fade %d,%d,%d a%d, world %d, centre %d, eye height %.0f, "
            "Link at (%.0f, %.0f, %.0f) facing %d, turn %.0f deg\n",
            s_ticks, CameraLeads() ? (dComIfGp_event_runCheck() ? "event" : "camera leads") : "first person",
            dMenu_flag(), fade.r, fade.g, fade.b, fade.a, g_worldVisible ? 1 : 0, g_centreValid ? 1 : 0,
            g_eyeHeight, player != NULL ? player->current.pos.x : 0.0f, player != NULL ? player->current.pos.y : 0.0f,
            player != NULL ? player->current.pos.z : 0.0f, player != NULL ? player->shape_angle.y : 0,
            g_turn * 180 / kPi);
    }
    return g_drawing;
}

bool wwvr_vr_drawing(void) {
    return g_drawing;
}

int wwvr_vr_eye_first(void) {
    return 0;
}

int wwvr_vr_eye_next(int eye) {
    return g_drawing && eye == 0 ? 1 : -1;
}

void wwvr_vr_eye_begin(int eye) {
    if (!g_drawing) {
        return;
    }
    view_class* view = dComIfGd_getView();
    if (view == NULL) {
        return;
    }
    g_eye = eye;
    g_eyeView = view;
    // The eye's view and its offset from the centre view. In gameplay the view turns with the stick
    // and moves with Link between ticks (from the centre view's anchor at his last speed); events
    // keep the camera's.
    float base = g_viewBase;
    float anchor[3] = {g_viewAnchor[0], g_viewAnchor[1], g_viewAnchor[2]};
    if (!g_viewCameraLeads) {
        base = g_turn;
        const float since = static_cast<float>(fmin(fmax(Seconds() - g_viewTime, 0.0), 0.05));
        for (int i = 0; i < 3; ++i) {
            anchor[i] += g_anchorVelocity[i] * since;
        }
    }
    float pos[3], rot[3][3];
    PlacePose(g_frame.eye[eye], base, anchor, pos, rot);
    Mtx eyeView, inverse, t;
    ViewOf(pos, rot, eyeView);
    MTXInverse(g_centreView, inverse);
    MTXConcat(eyeView, inverse, t);
    const f32 t44[4][4] = {{t[0][0], t[0][1], t[0][2], t[0][3]},
                           {t[1][0], t[1][1], t[1][2], t[1][3]},
                           {t[2][0], t[2][1], t[2][2], t[2][3]},
                           {0, 0, 0, 1}};
    // The eye's projection replaces the camera's for the camera block (its GXSetProjection calls).
    memcpy(g_savedProj, view->mProjMtx, sizeof(Mtx44));
    FovToProj(g_frame.fov[eye], view->mNear, view->mFar, view->mProjMtx);

    aurora::gfx::create_pass(g_frame.width, g_frame.height);
    GXAuroraSetOffscreenNativeLogical(GX_TRUE);
    GXAuroraSetEyeTransform(t44);

    // The pass starts cleared to black; the game's EFB starts at its back colour.
    FillPass(mDoGph_gInf_c::getBackColor());
}

void wwvr_vr_eye_end(int eye) {
    if (!g_drawing || g_eye != eye) {
        return;
    }
    if (eye == 0 && g_eyeView != NULL) {
        // GXPeekZ (the sun's glare, lanterns) reads the frame's depth snapshot at points the game
        // projected with its camera's (symmetric) field of view: this eye's depth is the snapshot,
        // read where that field of view puts each point in it.
        const float tanY = tanf(g_eyeView->mFovy * 0.5f * kPi / 180.0f);
        const float tanX = tanY * g_eyeView->mAspect;
        const wwvr_xr_fov& fov = g_frame.fov[0];
        const float tl = tanf(fov.left), tr = tanf(fov.right), tu = tanf(fov.up), td = tanf(fov.down);
        if (tr > tl && tu > td && tanX > 0 && tanY > 0) {
            GXAuroraDepthSnapshotHere((-tanX - tl) / (tr - tl), (tu - tanY) / (tu - td), 2.0f * tanX / (tr - tl),
                                      2.0f * tanY / (tu - td));
        }
    }
    GXAuroraSetEyeTransform(NULL);
    GXAuroraSetOffscreenNativeLogical(GX_FALSE);
    if (g_eyeView != NULL) {
        memcpy(g_eyeView->mProjMtx, g_savedProj, sizeof(Mtx44));
        GXSetProjection(g_eyeView->mProjMtx, GX_PERSPECTIVE);
    }
    aurora::gfx::ResolvedTargets targets;
    if (aurora::gfx::resolve_pass({.color = true}, targets) && targets.colorTexture) {
        wwvr_xr_submit_eye(eye, targets.colorTexture.Get());
    }
    g_eye = -1;
    g_eyeView = nullptr;
}

bool wwvr_vr_eye_once(int eye) {
    return !g_drawing || eye == 0;
}

bool wwvr_vr_fade_steps(void) {
    return !g_drawing || (g_eye <= 0 && !g_repainting);
}

bool wwvr_vr_repaint_due(void) {
    if (!g_frame.render || !g_haveHead || !wwvr_xr_running() || wwvr_window_enabled() ||
        g_frame.display_period_ns <= 0 || g_repaints >= 3) {
        return false;
    }
    // Another refresh (which waits for the display's next frame) only if it ends before the next
    // tick is due (1/30 s after this one began), with a little to spare.
    const double period = static_cast<double>(g_frame.display_period_ns) * 1e-9;
    if (Seconds() + period * 0.85 > g_tickStart + 1.0 / 30.0 - 0.002) {
        return false;
    }
    ++g_repaints;
    return true;
}

void wwvr_vr_repaint(void) {
    wwvr_frame_boundary();
    bool begun;
    {
        JKRPcHostAllocScope host;  // Aurora's frame work: host memory, as in pc_frame.cpp
        begun = aurora_begin_frame();
    }
    if (!begun) {
        return;
    }
    g_repainting = true;
    mDoGph_Repaint();
    g_repainting = false;
    {
        JKRPcHostAllocScope host;
        aurora_end_frame();
    }
    wwvr_vr_frame_end();
}

bool wwvr_vr_screen_effects(void) {
    return !g_drawing;
}

bool wwvr_vr_world_visible(void) {
    return !g_drawing || (g_worldVisible && g_centreValid);
}

int wwvr_vr_panel_first(void) {
    return 0;
}

int wwvr_vr_panel_next(int pass) {
    return Panels() && pass == 0 ? 1 : -1;
}

bool wwvr_vr_panels(void) {
    return Panels();
}

void wwvr_vr_panel_begin(int pass) {
    // Over black (pass 0) or over white (pass 1): the two make the 2D's transparency.
    const GXColor colour = pass == 0 ? GXColor{0, 0, 0, 255} : GXColor{255, 255, 255, 255};
    if (!g_drawing) {
        // The window's HUD layer: the pass starts cleared to black, so only the white one is filled,
        // and neither's alpha is written (the two passes start alike for the game's alpha masks).
        if (wwvr_window_hud_begin(pass)) {
            if (pass == 1) {
                GXSetAlphaUpdate(GX_FALSE);
                FillPass(colour);
            } else {
                j3dSys.reinitGX();
                J3DShape::resetVcdVatCache();
            }
        }
        return;
    }
    uint32_t width = 0, height = 0;
    wwvr_xr_panel_size(&width, &height);
    aurora::gfx::create_pass(width, height);
    GXAuroraSetOffscreenNativeLogical(GX_TRUE);
    FillPass(colour);
}

void wwvr_vr_panel_end(int pass) {
    if (!g_drawing) {
        wwvr_window_hud_end(pass);
        return;
    }
    if (pass < 0 || pass > 1) {
        return;
    }
    GXAuroraSetOffscreenNativeLogical(GX_FALSE);
    g_panelTargets[pass] = {};
    aurora::gfx::resolve_pass({.color = true}, g_panelTargets[pass]);
    if (pass == 1 && g_panelTargets[0].colorTexture && g_panelTargets[1].colorTexture) {
        wwvr_xr_submit_panel(g_panelTargets[0].colorTexture.Get(), g_panelTargets[1].colorTexture.Get(),
                             g_panelTargets[0].width, g_panelTargets[0].height);
    }
}

void wwvr_vr_frame_finish(void) {
    if (g_frameOpen) {
        wwvr_xr_finish_encoding();
    }
    g_panelTargets[0] = {};
    g_panelTargets[1] = {};
    g_drawing = false;
}

void wwvr_vr_frame_end(void) {
    if (!g_frameOpen) {
        return;
    }
    g_frameOpen = false;
    wwvr_xr_end_frame();
}

void wwvr_vr_camera(void* view_ptr) {
    float anchor[3], base, pos[3], rot[3][3];
    OverrideView(static_cast<view_class*>(view_ptr), anchor, &base, pos, rot);
}

void wwvr_vr_camera_draw(void* view_ptr) {
    float anchor[3], base, pos[3], rot[3][3];
    if (!OverrideView(static_cast<view_class*>(view_ptr), anchor, &base, pos, rot)) {
        // These lists aren't made from the head (the session is stopped): no eyes from them.
        g_centreValid = false;
        return;
    }
    // What the draw lists are made with this frame, and Link's speed since the last.
    const double now = Seconds();
    const bool leads = CameraLeads();
    const double dt = now - g_viewTime;
    if (!leads && !g_viewCameraLeads && dt > 0.005 && dt < 0.2) {
        for (int i = 0; i < 3; ++i) {
            const float v = (anchor[i] - g_viewAnchor[i]) / static_cast<float>(dt);
            // A teleport or a cut isn't a speed.
            g_anchorVelocity[i] = fabsf(v) < 3000.0f ? v : 0.0f;
        }
    } else {
        g_anchorVelocity[0] = g_anchorVelocity[1] = g_anchorVelocity[2] = 0;
    }
    ViewOf(pos, rot, g_centreView);
    g_centreValid = true;
    g_viewBase = base;
    g_viewAnchor[0] = anchor[0];
    g_viewAnchor[1] = anchor[1];
    g_viewAnchor[2] = anchor[2];
    g_viewCameraLeads = leads;
    g_viewTime = now;
}

bool wwvr_vr_held_mtx(int role, const float model_min[3], const float model_max[3], int shield, float out[3][4]) {
    if (!wwvr_vr_first_person() || role < 0 || role > 1) {
        return false;
    }
    const int hand = role == 0 ? SwordHand() : 1 - SwordHand();
    if (!g_frame.input.tracked[hand]) {
        return false;
    }
    // The hand's grip in the world, as the eyes are placed.
    float base = g_turn;
    float anchor[3] = {g_viewAnchor[0], g_viewAnchor[1], g_viewAnchor[2]};
    float pos[3], grip[3][3];
    PlacePose(g_frame.input.grip[hand], base, anchor, pos, grip);
    // The model's axes onto the grip's. A sword: its longest extent (from the hilt at its origin)
    // along the grip's forward (-Z), its width across (+X). A shield: its thinnest extent (its
    // face) forward, its longest up (+Y).
    float extent[3];
    for (int i = 0; i < 3; ++i) {
        extent[i] = model_max[i] - model_min[i];
    }
    int order[3] = {0, 1, 2};  // longest first
    for (int i = 0; i < 2; ++i) {
        for (int j = 0; j < 2 - i; ++j) {
            if (extent[order[j]] < extent[order[j + 1]]) {
                const int t = order[j];
                order[j] = order[j + 1];
                order[j + 1] = t;
            }
        }
    }
    float image[3][3] = {};  // image[axis] = where the model's axis goes, in the grip's frame
    if (!shield) {
        const int a = order[0], b = order[1];
        const float sign = fabsf(model_max[a]) >= fabsf(model_min[a]) ? 1.0f : -1.0f;
        image[a][2] = -sign;
        image[b][0] = 1.0f;
    } else {
        const int a = order[0], c = order[2];
        image[a][1] = 1.0f;
        image[c][2] = -1.0f;
    }
    // The third axis completes a rotation: e_k = e_i x e_j for (i, j, k) in cyclic order.
    for (int k = 0; k < 3; ++k) {
        const float* x = image[(k + 1) % 3];
        const float* y = image[(k + 2) % 3];
        const float lenK = fabsf(image[k][0]) + fabsf(image[k][1]) + fabsf(image[k][2]);
        if (lenK == 0.0f) {
            image[k][0] = x[1] * y[2] - x[2] * y[1];
            image[k][1] = x[2] * y[0] - x[0] * y[2];
            image[k][2] = x[0] * y[1] - x[1] * y[0];
        }
    }
    // World rotation = grip * align, where align's columns are the images.
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            out[r][c] = grip[r][0] * image[c][0] + grip[r][1] * image[c][1] + grip[r][2] * image[c][2];
        }
        out[r][3] = pos[r];
    }
    return true;
}

bool wwvr_vr_first_person(void) {
    return g_haveHead && g_placed && !wwvr_window_enabled() && wwvr_xr_running() && !CameraLeads();
}

bool wwvr_vr_control_yaw(short* yaw) {
    if (yaw == NULL || !g_haveHead || !g_placed || wwvr_window_enabled() || !wwvr_xr_running() || CameraLeads()) {
        return false;
    }
    // The camera's controlled yaw points from what it looks at back to it: the head's forward + pi.
    const float forward = g_turn + LocalYaw(g_frame.head.orientation) + kPi;
    *yaw = static_cast<short>(lroundf(Wrap(forward + kPi) * kS16PerRadian));
    return true;
}

void wwvr_vr_pad_feed(void) {
    static bool fed = false;
    if (!g_haveHead || wwvr_window_enabled() || !wwvr_xr_running()) {
        if (fed) {
            // Aurora keeps a virtual pad's last state: let go of what the controllers held.
            PADClearVirtualStatus(0);
            fed = false;
        }
        return;
    }
    fed = true;
    const wwvr_xr_input& in = g_frame.input;
    PADStatus status;
    memset(&status, 0, sizeof(status));
    const auto axis = [](float v) {
        const float c = fmaxf(-1.0f, fminf(1.0f, v));
        return static_cast<s8>(lroundf(c * 100.0f));
    };
    // Wind Waker's VR layout on the Touch bindings the provider gives the Sense controllers and
    // bare hands (PortContent.swift's Controls tab draws it): the face buttons as on the pad,
    // the left trigger targets, the left grip raises the shield, the right trigger is Z, the right
    // grip the map, Create the items menu; the sword hand's swing is the sword.
    status.stickX = axis(in.stick_x[WWVR_XR_LEFT]);
    status.stickY = axis(in.stick_y[WWVR_XR_LEFT]);
    if (in.primary[WWVR_XR_RIGHT]) status.button |= PAD_BUTTON_A;
    if (in.secondary[WWVR_XR_RIGHT]) status.button |= PAD_BUTTON_B;
    if (in.primary[WWVR_XR_LEFT]) status.button |= PAD_BUTTON_X;
    if (in.secondary[WWVR_XR_LEFT]) status.button |= PAD_BUTTON_Y;
    if (in.trigger[WWVR_XR_LEFT] > 0.5f) {
        status.button |= PAD_TRIGGER_L;
        status.triggerLeft = 180;
    }
    if (in.squeeze[WWVR_XR_LEFT] > 0.6f) {
        status.button |= PAD_TRIGGER_R;
        status.triggerRight = 180;
    }
    if (in.trigger[WWVR_XR_RIGHT] > 0.5f) status.button |= PAD_TRIGGER_Z;
    if (in.squeeze[WWVR_XR_RIGHT] > 0.6f) status.button |= PAD_BUTTON_UP;
    if (in.menu) status.button |= PAD_BUTTON_START;
    if (in.stick_click[WWVR_XR_RIGHT]) status.button |= PAD_BUTTON_LEFT;
    if (in.stick_click[WWVR_XR_LEFT]) status.button |= PAD_BUTTON_RIGHT;
    if (g_swingTicks > 0) {
        status.button |= PAD_BUTTON_B;
        --g_swingTicks;
    }
    // The right stick turns (wwvr_vr_frame_begin); up and down are the C stick's (the telescope).
    status.substickY = axis(in.stick_y[WWVR_XR_RIGHT]);
    PADSetVirtualStatus(0, &status);
}

}  // extern "C"
