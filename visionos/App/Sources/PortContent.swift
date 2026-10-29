import SwiftUI
import TrevorbiltKit

/// Everything in the launcher that's this port's own: its name, the ways it plays and what each
/// plays with, what pausing can do, its game files, Advanced options, the controls, credits and
/// licences. The layout and scene plumbing (LauncherView, ControlsView, GameModel) and
/// TrevorbiltKit are shared by every Trevorbilt port: change them only to fix them for all.
///
/// Fill every TODO. Copy: plain, warm, low pressure; short direct verbs ("Play", "Resume"); no em
/// dashes; errors say what to do. Run new copy past the trevorbilt-critic agent.
enum Port {
    // MARK: Who and where

    /// The port's name, its last word bold in the header.
    static let title = "Wind Waker "
    static let boldTitle = "VR"
    /// "<the game's full title> on Apple Vision Pro" (not "in VR": Window isn't VR).
    static let subtitle = "The Legend of Zelda: The Wind Waker on Apple Vision Pro"
    /// The public release, "owner/name", and its branch: the update check, Report a problem (its
    /// issues), the GPL source offer. The "Build commit" phase in project.yml names it too.
    static let repository = "edgytoast/windwaker-visionos"
    static let releaseBranch = "visionos"
    /// The port's id in the AVP Ports Index once listed (not listed: the port is local only).
    static let indexID = "wind-waker-vr"
    /// How a player updates once the update check finds a newer version.
    static let updateInstructions = "git fetch, then check out the commit the AVP Ports Index lists (or git pull on the visionos branch), then visionos/scripts/build-visionos.sh --team <your team> --install (AVP-INSTALL.md has the details). Your game files and saves stay."

    // MARK: Modes

    /// The ways this port plays, in the order shown.
    static let modes: [GameModel.Immersion] = [.window, .full, .progressive]

    /// Modes in the app that haven't been played on a headset yet: Play shows them only once the
    /// player turns them on under the cards, and says so. Full and Progressive are built and run
    /// in the Simulator, but their stereo, comfort, frame rate, hands and Sense controllers are
    /// unchecked on a headset. Empty this once they have been played there.
    static let experimentalModes: Set<GameModel.Immersion> = [.full, .progressive]
    /// The switch under the cards, and what an experimental mode's card says above its note.
    static let experimentalTitle = "Try Full and Progressive (experimental)"
    static let experimentalNote = "Experimental: not yet played on a headset, so stereo, comfort and frame rate are untested. Take it slow, and stop if anything feels off."

    /// One line on each mode's card.
    static func line(_ mode: GameModel.Immersion) -> String {
        switch mode {
        case .full: "Experimental. All around you, in first person."
        case .progressive: "Experimental. A portal in your room; the Crown widens it."
        case .window: "The Great Sea in 3D, beside your other apps."
        }
    }

    /// One plain sentence under the cards on what the selected mode (and its option) does.
    static func note(_ mode: GameModel.Immersion, roomBehindMenus: Bool) -> String {
        switch mode {
        case .full where roomBehindMenus:
            "Menus and loading screens float in your room. Walk about 1.2 m from where you started and the game fades into the room."
        case .full:
            "The game stays around you in menus too, with visionOS's own boundary."
        case .progressive:
            "Turn the Digital Crown to widen or narrow the portal. Press it to pause."
        case .window:
            windowClosePauses ? "Real depth you can see as you move, or 2D like the original. Plays with a controller. Close the window to pause."
                              : "Real depth you can see as you move, or 2D like the original. Plays with a controller. Close the window to quit."
        }
    }

    // MARK: Pause capabilities

    /// The Digital Crown closing Full or Progressive pauses the game, and the launcher comes back
    /// with Resume. Needs a game that holds its session and takes a new layer (wwvr_visionos_can_resume).
    static let crownPauses = true
    /// Quit beside Resume: the game quits through its own window-closed path (an SDL quit event).
    static let quitsFromPause = true
    /// Closing the game's window ends the game and the app (it quits like a closed desktop window).
    static let windowClosePauses = false
    /// What Quit keeps, said beside Resume.
    static let pausedNote = "Resume carries on where you were. Quit keeps your progress up to your last save."

    // MARK: Inputs (mode → inputs)

    /// Which inputs each mode plays with, and whether they're here. The hands verdict never
    /// promises more than the port delivers; denied hands never block controller play; Open
    /// Settings only when the mode needs hands and no controller is connected.
    @MainActor static func verdict(_ mode: GameModel.Immersion, _ inputs: InputMonitor) -> InputVerdict {
        if mode == .window {
            // Two Sense controllers make one gamepad in the window (host/sense_pad).
            if inputs.senseLeft != nil && inputs.senseRight != nil {
                return InputVerdict("Ready to play with your Sense controllers, as a gamepad.", ready: true)
            }
            if inputs.anySense {
                return InputVerdict("Only one Sense controller is connected. Turn on the other, or turn this one off to play with a gamepad.", ready: false)
            }
            if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
            return InputVerdict("The Window view plays with a controller. Connect your Sense controllers or a gamepad.", ready: false)
        }
        // Full and Progressive: each hand is a Sense controller if one's in it, else the bare hand;
        // a gamepad plays alongside either.
        let handsPlay = inputs.hands == .allowed || inputs.hands == .notAsked
        if inputs.senseLeft != nil && inputs.senseRight != nil {
            if inputs.accessories == .denied && !handsPlay {
                return InputVerdict("Accessory tracking is off for Wind Waker VR, so the game can't follow your controllers. Turn it on in Settings.",
                                    ready: false, settingsNeeded: true)
            }
            return InputVerdict("Ready to play with your Sense controllers. Have fun!", ready: true)
        }
        if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
        if inputs.anySense {
            return handsPlay
                ? InputVerdict("Ready with one Sense controller. Your other hand plays bare.", ready: true)
                : InputVerdict("Only one Sense controller is connected and hand tracking is off. Turn on the other controller, or turn hand tracking on in Settings.",
                               ready: false, settingsNeeded: true)
        }
        switch inputs.hands {
        case .allowed:
            return InputVerdict("Ready to play with your hands. The Controls tab shows how.", ready: true)
        case .notAsked:
            return InputVerdict("Your hands play. visionOS asks to track them when the game starts.", ready: true)
        case .denied:
            return InputVerdict("Hand tracking is off for Wind Waker VR. Turn it on in Settings, or connect a controller.",
                                ready: false, handsNeeded: true)
        case .unavailable:
            return InputVerdict("No controller is connected, and hand tracking isn't available here.", ready: false)
        }
    }

    // MARK: Game files

    /// What the player calls the game's files, as the card says it.
    static let filesNoun = "disc"
    static let filesSymbol = "opticaldisc.fill"
    /// Which files, which releases, and the ways in (AirDrop, Files, Import).
    static let filesHelp = "Your own copy of the US GameCube disc (GZLE01, the original release) as an uncompressed .iso. AirDrop it to this Vision Pro, put it in Files › On My Apple Vision Pro › Wind Waker VR, or import it here."

    /// Why an imported file whose kind the game can't load isn't brought in (GameModel.assetExtensions).
    static func unsupportedFile(_ file: URL) -> String {
        ["rvz", "ciso", "gcz", "wia", "nkit"].contains(file.pathExtension.lowercased())
            ? "\(file.lastPathComponent) is a compressed image. Convert it to an uncompressed .iso first (Dolphin's Convert File does it), then bring that in."
            : "\(file.lastPathComponent) isn't a disc image Wind Waker VR can read. It plays an uncompressed .iso of the US disc."
    }

    /// Whether `file` is the release the game plays: the disc header's game ID (bytes 0-5) must be
    /// GZLE01 and its version (byte 7) 0, as the game's own check (pc_main.cpp) wants, and a full
    /// GameCube disc is 1,459,978,240 bytes. Runs off the main thread before Play is enabled.
    nonisolated static func validate(_ link: URL) -> String? {
        // A test bench links the disc in place rather than copying 1.4 GB: judge what it points at.
        let file = link.resolvingSymlinksInPath()
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return "The file is empty. Import it again." }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "The file can't be read. Import it again." }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else {
            return "The file is too short to be a disc. Import it again."
        }
        let id = String(decoding: header.prefix(6), as: UTF8.self)
        if id.hasPrefix("GZLP") || id.hasPrefix("GZLJ") {
            return "This is a European or Japanese disc. Wind Waker VR plays the US release (GZLE01)."
        }
        guard id == "GZLE01" else {
            return "This isn't The Wind Waker's US disc (GZLE01). Compressed images (.rvz, .ciso) need converting to .iso first."
        }
        guard header[7] == 0 else { return "This is a later revision of the disc. Wind Waker VR plays the original release (revision 0)." }
        guard size >= 1_459_978_240 else { return "The disc image is cut short. Import it again." }
        return nil
    }

    // MARK: Advanced options

    /// Options that must be set before Play (read on the first frame) and that most players never
    /// touch. In-game options belong in the game's own settings menu instead.
    struct AdvancedOptions: View {
        @ObservedObject var model: GameModel
        // Comfort and picture options for Full and Progressive, read by the game while it runs
        // (visionos/host/wwvr_xr.mm, wwvr_xr_get_comfort): TPVR's defaults.
        @AppStorage("vrSnapTurn") private var snapTurn = false
        @AppStorage("vrSnapTurnDegrees") private var snapDegrees = 45
        @AppStorage("vrSmoothTurnSpeed") private var smoothSpeed = 135
        @AppStorage("vrAntiAliasing") private var antiAliasing = 2
        @AppStorage("vrSwordHand") private var swordHand = 0
        @AppStorage("vrRenderScale") private var renderScale = 100

        var body: some View {
            VStack(spacing: 12) {
                TrevorbiltCard {
                    VStack(alignment: .leading, spacing: 10) {
                        option("Turning", "In Full and Progressive, the right stick turns you. Smooth turning glides; turning in steps is gentler if gliding makes you queasy.")
                        Picker("Turning", selection: $snapTurn) {
                            Text("Smooth").tag(false)
                            Text("In steps").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if snapTurn {
                            Picker("Step", selection: $snapDegrees) {
                                ForEach([30, 45, 60, 90], id: \.self) { Text("\($0)°").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            HStack {
                                Text("Speed").font(.tbBody(12))
                                Slider(value: Binding(get: { Double(smoothSpeed) }, set: { smoothSpeed = Int($0) }),
                                       in: 60...270, step: 15)
                                    .tint(Trevorbilt.orange)
                                Text("\(smoothSpeed)° a second").font(.tbBody(12)).monospacedDigit()
                                    .frame(width: 120, alignment: .trailing)
                            }
                        }
                    }
                }
                TrevorbiltCard {
                    VStack(alignment: .leading, spacing: 10) {
                        option("Sword hand", "The hand that holds Link's sword in Full and Progressive, and swings it. The shield goes in the other.")
                        Picker("Sword hand", selection: $swordHand) {
                            Text("Right").tag(0)
                            Text("Left").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                TrevorbiltCard {
                    VStack(alignment: .leading, spacing: 10) {
                        option("Render resolution", "The eye images' size in Full and Progressive, against what visionOS asks for. Higher is sharper and costs GPU time; lower it if the game stutters. Takes effect from the next Play.")
                        HStack {
                            Slider(value: Binding(get: { Double(renderScale) }, set: { renderScale = Int($0) }),
                                   in: 50...150, step: 10)
                                .tint(Trevorbilt.orange)
                            Text("\(renderScale)%").font(.tbBody(12)).monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                TrevorbiltCard {
                    VStack(alignment: .leading, spacing: 10) {
                        option("Smoothing edges", "Anti-aliasing on the game's picture in Full and Progressive. SMAA is the sharpest; FXAA costs less.")
                        Picker("Smoothing edges", selection: $antiAliasing) {
                            Text("Off").tag(0)
                            Text("FXAA").tag(1)
                            Text("SMAA").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                TrevorbiltCard {
                    Toggle(isOn: $model.foveated) {
                        option("Foveated rendering", "In Full: sharper where you look. The game renders larger eye images for it, which costs GPU time.")
                    }
                    .tint(Trevorbilt.orange)
                }
            }
        }

        private func option(_ title: String, _ detail: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.tbBody(14, weight: .bold))
                Text(detail)
                    .font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Controls

    /// Which way the game's camera turns for the right stick (the GameCube's C stick) in the
    /// Window view, set in the Controls tab and kept in UserDefaults. Left and right: Modern by
    /// default, push right and the view turns right (what most players expect now, and Wind
    /// Waker HD's option), or Classic, the GameCube's way round. Up and down: as the game has it,
    /// or inverted. The game takes it before Play (SwitchWaker's COS_CAMERA_INVERT_X/Y) and at
    /// once while playing (wwvr_visionos_set_camera_invert): only the camera; Full and
    /// Progressive's turning keeps the stick's own directions.
    enum CameraDirections {
        static let classicLeftRightKey = "cameraClassicLeftRight"
        static let invertedUpDownKey = "cameraInvertedUpDown"
        static var classicLeftRight: Bool { UserDefaults.standard.bool(forKey: classicLeftRightKey) }
        static var invertedUpDown: Bool { UserDefaults.standard.bool(forKey: invertedUpDownKey) }

        /// Tells the game, before Play or while it runs.
        static func apply() {
            wwvr_visionos_set_camera_invert(!classicLeftRight, invertedUpDown)
        }

        /// The Controls tab's camera card: each choice's title, its two options, and what the one
        /// chosen does.
        static let leftRightTitle = "Camera left and right"
        static let leftRightOptions = (off: "Modern", on: "Classic (GameCube)")
        static func leftRightDetail(classic: Bool) -> String {
            classic ? "As on the GameCube: push the right stick right and the camera swings round the other way."
                    : "Push the right stick right and the view turns right, as in most games today."
        }
        static let upDownTitle = "Camera up and down"
        static let upDownOptions = (off: "Normal", on: "Inverted")
        static func upDownDetail(inverted: Bool) -> String {
            inverted ? "Up and down the other way round from the original game." : "Up and down as in the original game."
        }

        /// The right stick's callout in the Window view.
        static var stickAction: String {
            var action = classicLeftRight ? "Camera, the GameCube way" : "Camera"
            if invertedUpDown { action += ", up and down inverted" }
            return action
        }
    }

    /// The hands' gestures, on two pages (the other inputs fit on one).
    static let controlPages: [String] = ["Moving", "Items"]

    /// The game's controls, read from the game (d_a_player_main.cpp's setStickData: A action, B
    /// sword, X/Y/Z items, L target, R shield; Start the items menu; the D-pad the maps,
    /// d_menu_window.cpp and d_meter.cpp) and from the port:
    /// - Full and Progressive (visionos/game/wwvr_vr.cpp, wwvr_vr_pad_feed): the Touch bindings the
    ///   OpenXR provider gives the Sense controllers and bare hands, with the right stick turning and
    ///   the sword hand's swing as the sword.
    /// - A gamepad: Aurora's standard mapping (south A, east B, west X, north Y, right shoulder Z,
    ///   the triggers L and R), the right stick turning in Full and Progressive.
    /// - The Window view's Sense controllers: one gamepad (visionos/host/sense_pad.mm's Layout).
    static func controls(_ input: ControlsView.Input, window: Bool, page: Int) -> [ControlItem] {
        func button(_ n: Int, _ action: String, _ how: String, _ anchor: String?, also: [String: String] = [:]) -> ControlItem {
            ControlItem(n, action, how, anchor: anchor, also: also)
        }
        func hand(_ n: Int, _ action: String, _ how: String, _ anchor: String, _ pose: HandPose) -> ControlItem {
            ControlItem(n, action, how, anchor: anchor, pose: .hand(pose))
        }
        switch (input, window) {
        case (.hands, _) where page == 0:
            return [hand(1, "Walk", "Pinch your left thumb and middle finger, hold, and move your hand.", "leftMiddle", .pinchMiddleLeftMove),
                    hand(2, "Turn", "Pinch your right thumb and little finger, hold, and move it sideways.", "rightLittle", .pinchLittleRightTurn),
                    hand(3, "Action", "Pinch your right thumb and middle finger: talk, open, climb, roll.", "rightMiddle", .pinchMiddleRight),
                    hand(4, "Sword", "Swing your sword hand, or pinch your right thumb and ring finger.", "rightPalm", .swingRight),
                    hand(5, "Shield", "Make a fist with your left hand and hold it.", "leftPalm", .fistLeft),
                    hand(6, "Target", "Pinch your left thumb and index finger, and hold.", "leftIndex", .pinchIndexLeft)]
        case (.hands, _):
            return [hand(1, "Item (X)", "Tap your left thumb and middle finger. (Hold them to walk.)", "leftMiddle", .pinchMiddleLeft),
                    hand(2, "Item (Y)", "Pinch your left thumb and ring finger.", "leftRing", .pinchRingLeft),
                    hand(3, "Item (Z)", "Pinch your right thumb and index finger.", "rightIndex", .pinchIndexRight),
                    hand(4, "Map", "Make a fist with your right hand.", "rightPalm", .fistRight),
                    hand(5, "Items menu", "Pinch your left thumb and little finger: items, quest status, the map. The game waits.",
                         "leftLittle", .pinchLittleLeft)]
        case (.sense, false):
            return [button(1, "Move", "Left stick (click it for the small map)", "leftStick", also: ["leftStick": "Small map (click)"]),
                    button(2, "Turn", "Right stick, or just turn around (click it for the small map)", "rightStick",
                           also: ["rightStick": "Small map (click)"]),
                    button(3, "Action", "Cross: talk, open, climb, roll", "a"),
                    button(4, "Sword", "Circle, or swing your sword hand", "b"),
                    button(5, "Item (X)", "Square", "x"),
                    button(6, "Item (Y)", "Triangle", "y"),
                    button(7, "Item (Z)", "R2, the right trigger", "rightTrigger"),
                    button(8, "Target", "Hold L2, the left trigger", "leftTrigger"),
                    button(9, "Shield", "Hold L1, the left grip", "leftShoulder"),
                    button(10, "Map", "R1, the right grip", "rightShoulder"),
                    button(11, "Items menu", "Create: items, quest status, the map", "view"),
                    button(12, "Sword", "swing your sword hand, as Link would", "swing")]
        case (.gamepad, false):
            return [button(1, "Move", "Left stick", "leftStick"),
                    button(2, "Turn", "Right stick, or just turn around", "rightStick"),
                    button(3, "Action", "Talk, open, climb, roll", "a"),
                    button(4, "Sword", "Swing it; hold to spin", "b"),
                    button(5, "Item", "The item on X", "x"),
                    button(6, "Item", "The item on Y", "y"),
                    button(7, "Item", "The item on Z", "rightShoulder"),
                    button(8, "Target", "Lock on and look", "leftTrigger"),
                    button(9, "Shield", "Hold to guard and crouch", "rightTrigger"),
                    button(10, "Items menu", "Items, quests and the map", "menu"),
                    button(11, "Maps", "Up: the map. Left and right: the small map", "dpad")]
        case (.sense, true):
            return [button(1, "Move", "Left stick (click it for the small map)", "leftStick", also: ["leftStick": "Small map (click)"]),
                    button(2, CameraDirections.stickAction, "Right stick (click it to close the map)", "rightStick",
                           also: ["rightStick": "Close the map (click)"]),
                    button(3, "Action", "Cross: talk, open, climb, roll", "a"),
                    button(4, "Sword", "Circle", "b"),
                    button(5, "Item (X)", "Square", "x"),
                    button(6, "Item (Y)", "Triangle", "y"),
                    button(7, "Item (Z)", "R1, the right grip", "rightShoulder"),
                    button(8, "Target", "L2, the left trigger", "leftTrigger"),
                    button(9, "Shield", "R2, the right trigger", "rightTrigger"),
                    button(10, "Map", "L1, the left grip", "leftShoulder"),
                    button(11, "Small map", "Create, on the left controller", "view"),
                    button(12, "Items menu", "Options, on the right controller", "menu")]
        case (.gamepad, true):
            return [button(1, "Move", "Left stick", "leftStick"),
                    button(2, CameraDirections.stickAction, "Right stick", "rightStick"),
                    button(3, "Action", "Talk, open, climb, roll", "a"),
                    button(4, "Sword", "Swing it; hold to spin", "b"),
                    button(5, "Item", "The item on X", "x"),
                    button(6, "Item", "The item on Y", "y"),
                    button(7, "Item", "The item on Z", "rightShoulder"),
                    button(8, "Target", "Lock on and look", "leftTrigger"),
                    button(9, "Shield", "Hold to guard and crouch", "rightTrigger"),
                    button(10, "Items menu", "Items, quests and the map", "menu"),
                    button(11, "Maps", "Up: the map. Left and right: the small map", "dpad"),
                    // L1 and Create are no game buttons on a gamepad (Aurora's standard mapping):
                    // together they switch the window (WindowDepthToggle.swift).
                    button(12, "2D or 3D", "L1 + Create (LB + View) together, or the button above the window's corner",
                           "leftShoulder", also: ["view": "2D or 3D (with the left shoulder)"])]
        }
    }

    /// One note under each page: what no drawing shows, and where a setting changes it.
    static func controlsNote(_ input: ControlsView.Input, window: Bool) -> String {
        switch (input, window) {
        case (.hands, _): "Hands play in Full and Progressive. A Sense controller takes over the hand holding it. Your sword hand is set in Advanced options."
        case (.sense, false): "Your sword follows your sword hand, the right unless you change it in Advanced options, and the shield your other hand while you guard. Turning is smooth or in steps, also in Advanced options."
        case (.gamepad, false): "In Full and Progressive a gamepad plays the original game's buttons while you look around the Great Sea. Sense controllers or your hands swing the sword for real."
        case (.sense, true): "The Window view plays like the original game, and your Sense controllers act as one gamepad. Look at the window to give it your controller."
        case (.gamepad, true): "The Window view plays like the original game, and it needs a controller: visionOS gives apps no hand tracking outside Full and Progressive. Look at the window to give it your controller. The game's world shows in 3D or, as the original, in 2D."
        }
    }

    // MARK: About

    /// The app links GPL code: Dolphin's DSP (GPL-2.0-or-later) and, from M2, the vendored OpenXR
    /// provider (GPL-3.0-or-later). About offers the source of this very build.
    static let appIsGPL = true

    /// The repository at the commit this build came from (a development build's isn't public, so
    /// the release branch): the GPL source offer.
    static var sourceOfThisBuild: URL? {
        let build = BuildInfo.current
        return URL(string: "https://github.com/\(repository)/tree/\(build.dirty ? releaseBranch : build.commit ?? releaseBranch)")
    }

    static var about: AboutContent {
        var notices: [AboutContent.Notice] = [
            .init("This repository: MIT, CC0 and GPL", "Trevorbilt's code for the port and SwitchWaker's are MIT. The decompiled game code is CC0. The audio's DSP code from Dolphin is GPL-2.0-or-later.",
                  URL(string: "https://github.com/\(repository)/blob/\(releaseBranch)/LICENSE")),
        ]
        if appIsGPL {
            notices.append(.init("This app: GPL-3.0", BuildInfo.current.dirty
                ? "It links Dolphin's DSP code (GPL-2.0-or-later) and the visionOS OpenXR provider (GPL-3.0-or-later), so the app is GPL-3.0. This is a development build: its source is the copy it was built from, and the repository has the released ones."
                : "It links Dolphin's DSP code (GPL-2.0-or-later) and the visionOS OpenXR provider (GPL-3.0-or-later), so the app is GPL-3.0. Its source is the repository at the commit this build came from.",
                sourceOfThisBuild))
        }
        notices += [
            .init("The launcher's shared code: MIT", "TrevorbiltKit, in visionos/TrevorbiltKit.",
                  URL(string: "https://github.com/\(repository)/blob/\(releaseBranch)/visionos/TrevorbiltKit/LICENSE")),
            .init("The launcher's fonts", "Space Mono and Roboto: SIL Open Font License 1.1.",
                  URL(string: "https://github.com/\(repository)/tree/\(releaseBranch)/visionos/TrevorbiltKit/Sources/TrevorbiltKit/Resources/Fonts")),
            .init("Third-party code", "Aurora is MIT. Dawn, SDL, nod, Dear ImGui and the other downloads keep their own licences."),
            .init("Trevorbilt's name, badge and app icons", "All rights reserved; not covered by the repository's licences."),
        ]
        return AboutContent(
            appName: "Wind Waker VR",
            repository: repository,
            releaseBranch: releaseBranch,
            updateInstructions: updateInstructions,
            // Trevorbilt first, then the lineage by name and link, as the README lists it.
            credits: [
                .init("Trevorbilt", "The Vision Pro port: the visionOS app, its immersive spaces and window, the input and the build.", "https://trevorbilt.com"),
                .init("Nintendo", "Made The Legend of Zelda: The Wind Waker, released in 2002 for GameCube.",
                      "https://en.wikipedia.org/wiki/The_Legend_of_Zelda:_The_Wind_Waker"),
                .init("zeldaret", "Decompiled it, with the wider GameCube decompilation community. snrubrm completed the functions still missing.",
                      "https://github.com/zeldaret/tww"),
                .init("SwitchWaker", "Compiled the decompilation natively on Aurora for the Mac, Linux and the Switch. This port builds directly on it.",
                      "https://github.com/centollOS/SwitchWaker"),
                .init("encounter", "Wrote Aurora, the GameCube graphics, input and disc layer.", "https://github.com/encounter/aurora"),
                .init("JoeyAW", "Made Twilight Princess VR, whose stereo view and VR hooks this port follows.", "https://github.com/JoeyAW/TPVR"),
                .init("iChris4", "Made WiiCompiled Vision, the source of the visionOS OpenXR provider.", "https://github.com/iChris4/Wiicompiled_VR"),
                .init("The Twilit Realm team", "Built Dusklight, the model for SwitchWaker's SDK layer.", "https://twilitrealm.dev"),
                .init("Dolphin and elliotttate", "Dolphin's DSP plays the game's audio, through elliotttate's adapter from Wind Waker Recomp.",
                      "https://dolphin-emu.org"),
            ],
            notices: notices,
            disclaimer: "Wind Waker VR is a fan project. It isn't affiliated with or endorsed by Nintendo, who own the game, its characters and its art. Your copy of the game is yours to bring.",
            otherPorts: [
                (name: "Twilight Princess VR", url: URL(string: "https://github.com/edgytoast/avp-ports-index/blob/main/ports/twilight-princess-vr.md")!),
                (name: "SHAR VR", url: URL(string: "https://github.com/edgytoast/avp-ports-index/blob/main/ports/shar-visionos.md")!),
                (name: "Animal Crossing VR", url: URL(string: "https://github.com/edgytoast/avp-ports-index/blob/main/ports/animal-crossing-vr.md")!),
            ],
            // Stays nil until Trevor gives a support link: never a placeholder.
            supportURL: nil)
    }
}
