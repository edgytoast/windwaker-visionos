import Foundation

/// The environment variables that drive the launcher's headless Simulator runs
/// (SIMCTL_CHILD_WWVR_TEST_…). They exist only in Simulator builds: an app installed on a headset
/// ignores them. Set but empty counts as not set, so a test script can pass every hook and leave the
/// ones it doesn't need blank. (WWVR_AUTO_PLAY and WWVR_IMMERSION read the environment directly,
/// so devicectl launches can use them too.)
///
///   WWVR_TEST_TAB=play|controls|ports|about            the tab to open on
///   WWVR_TEST_SHEET=manage|advanced|credits|diagnostics|port:<index id>
///   WWVR_TEST_INPUTS=hands:denied,sense:R,gamepad:none  what InputMonitor reports
///   WWVR_TEST_CONTROLS=hands|sense|gamepad[,window][,page=<n>][,bottom]
///   WWVR_TEST_PAD=none|xbox                            the gamepad drawing, as if none (an Xbox kind) were connected
///   WWVR_TEST_FEED=<host path>  WWVR_TEST_OFFLINE=1     the Ports tab's feed, or no network
///   WWVR_TEST_IMPORT=<host path>                       imports that file as if picked
///   WWVR_TEST_PAUSED=resume@<s>|quit@<s>               presses Resume or Quit after a Crown pause
///   WWVR_TEST_PROGRESSIVE_AMOUNT=<0.2...1>             the progressive portal's opening (GameModel)
///   WWVR_TEST_CROWN=<s>                                closes the immersive space that long after Play
///   WWVR_TEST_INTERRUPT=<s>~<length>                   an audio interruption that long after Play
///   WWVR_TEST_WINDOW_MIRROR=0  WWVR_TEST_WINDOW_TILT=<degrees>  WWVR_TEST_WINDOW_DUMP=<frame>
///   WWVR_TEST_WINDOW_EFFECTS=1|ghost  WWVR_TEST_WINDOW_MEMORY_MB=<n>   the window (GameWindowView)
///   WWVR_TEST_WINDOW_DEPTH=2d|3d[,2d@<s>,3d@<s>...]    the window's 2D/3D choice, and switches (s after launch)
///   WWVR_TEST_WINDOW_FLAT_MIRROR=1                     the mirror laid flat on the glass, to compare
///   WWVR_TEST_WINDOW_HOLD=<game frame>[+<s>]           the game's clock held there (and 2D s later)
///   WWVR_TEST_WINDOW_VIEW_SCALE=<scale>                how much wider than its picture the game draws in 3D
///   WWVR_TEST_WINDOW_REAIM=<fraction>[,<cap>[,<more>]] how much of the camera's downward pitch the window takes out (MirrorScene;
///                                                     1,20,0 by default: degrees)
///   WWVR_TEST_WINDOW_PITCH=<degrees>                   the window turned about its horizontal axis (seen from below)
///   WWVR_TEST_CAMERA_LIVE=<s>                          the camera's left and right turned over s s after Play (GameModel)
///   WWVR_TEST_WINDOW_RAISE=<fraction>                  how far the re-aimed eye is raised (1: the game camera's height)
///   WWVR_TEST_WINDOW_NO_EASE=1                         nothing in front of the glass cut or eased (the front allowance 0)
///   WWVR_TEST_MIRROR_DUMP=<frame>  WWVR_TEST_MIRROR_CULL=…  WWVR_TEST_MIRROR_ADD_RED=1
///   WWVR_TEST_MIRROR_ONE_MESH=1  WWVR_TEST_MIRROR_ONE_LEVEL_MESH=1   the scene mirror (MirrorScene)
/// Native ones, also Simulator builds only: WWVR_TEST_ACTIONS (the provider's scripted
/// controllers), WWVR_TEST_HANDS, WWVR_TEST_SWING (wwvr_xr.mm), WWVR_TEST_SWORD (wwvr_vr.cpp),
/// WWVR_TEST_WINDOW_HUD=frame (wwvr_window.cpp: the HUD found from the finished frame, as before),
/// WWVR_TEST_TIME=<hour> (wwvr_vr.cpp: the time of day, once the player is in a stage).
/// Deliberately read in every build, for devicectl launches: WWVR_AUTO_PLAY, WWVR_IMMERSION,
/// WWVR_ARGS (COS_* options, game_host.mm), WWVR_RENDER_SCALE, and the logs WWVR_GPU_TIMING and
/// WWVR_COMPOSITOR_LOG.
enum TestHooks {
    static func value(_ name: String) -> String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }

    /// Seconds since the process started (the kernel's start time), for scripted steps a test
    /// harness outside times its screenshots by.
    static func secondsSinceLaunch() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6)
    }
}
