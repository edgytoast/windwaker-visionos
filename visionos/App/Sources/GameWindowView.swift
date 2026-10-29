import GameController
import Metal
import RealityKit
import SwiftUI
import Synchronization

/// The game in a window in the shared space (Immersion: Window), beside other apps, moved and
/// resized with visionOS's own controls. visionOS gives no head pose outside a Full Space, so the
/// game plays flat, with its own camera and a gamepad. Behind a portal in the window, the scene
/// mirror (MirrorScene) rebuilds the game's 3D draws each frame for RealityKit to render from the
/// viewer's real eyes, so the game's world has true depth from any angle. The game's frames
/// (host/window_frames.h) add the rest: the HUD, fades and letterbox bars flat on the window's
/// glass (the other screen effects' layer is a test option). Frames with
/// no 3D scene (title, loading, films) show flat on the glass. From the TPVR port
/// (visionos/App/Sources/GameWindowView.swift), whose window followed the SHAR port's.
struct GameWindowView: View {
    @EnvironmentObject private var model: GameModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var updates: EventSubscription?
    @State private var aspect: CGFloat = 16.0 / 9.0
    // The window's size: the picture is fitted in it, at the game's aspect.
    @State private var windowSize: CGSize = .zero
    // 2D or 3D (WindowDepthToggle.swift). Test runs: WWVR_TEST_WINDOW_DEPTH=2d|3d[,2d@<s>,3d@<s>...]
    // starts so (over the kept choice) and switches at those seconds after the launch.
    @State private var depth = WindowDepth(initial: TestHooks.value("WWVR_TEST_WINDOW_DEPTH")
        .flatMap { WindowDepth.Mode(rawValue: String($0.split(separator: ",")[0])) })

    /// The picture's top-right corner in the window (unit coordinates): it's fitted at the game's
    /// aspect, and the window can be wider or taller.
    private var pictureTopTrailing: UnitPoint {
        guard windowSize.width > 0, windowSize.height > 0, aspect > 0 else { return .topTrailing }
        let width = min(windowSize.width, windowSize.height * aspect)
        let height = min(windowSize.height, windowSize.width / aspect)
        return UnitPoint(x: 0.5 + width / windowSize.width / 2, y: 0.5 - height / windowSize.height / 2)
    }

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                let screen: GameScreen
                do { screen = try await GameScreen(depth: depth) } catch {
                    print("[WWVR] the game window's materials failed to load: \(error)")
                    return
                }
                screen.aspectChanged = { aspect = CGFloat($0) }
                content.add(screen.root)
                GameScreen.fit(screen.root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                // RealityKit's updates pace the game: a frame per update while the window shows.
                updates = content.subscribe(to: SceneEvents.Update.self) { _ in screen.update() }
            } update: { content in
                if let root = content.entities.first {
                    GameScreen.fit(root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                }
            }
            // The window's face takes pinches and taps (the portal's collision box): without a
            // target they went through it to whatever was behind, another app's window or a widget
            // (the SHAR port found this on the headset). Nothing is done with them.
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in })
        }
        // 2D or 3D: a glass button just above the picture's top-right corner, clear of the window's
        // bar and close button below (inside the picture, it covered the game's own HUD there). The
        // window can be wider or taller than the picture: the button moves in to the picture's corner.
        .ornament(attachmentAnchor: .scene(pictureTopTrailing), contentAlignment: .bottomTrailing) {
            if depth.available {
                WindowDepthButton(depth: depth)
                    .padding(.bottom, 4)
                    // An ornament is hosted apart from the window's content: looking at the button,
                    // a gamepad's A would otherwise press it (a pinch) and the game lose the A.
                    .handlesGameControllerEvents(matching: .gamepad)
            }
        }
        // visionOS turns a game controller's buttons into pinches on whatever the player looks at,
        // unless the view says it reads the controller itself: with another window open the game
        // got nothing (SHAR). Looking at the game window gives it the controller.
        .handlesGameControllerEvents(matching: .gamepad)
        // Next to no depth, so the face is where the window's bar and corner handles are: given the
        // depth a plain window offers (as deep as it is tall), the face sat at the back of it and
        // didn't line up with them on the headset (SHAR). The game is behind the portal anyway.
        .frame(depth: 4)
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 4096, minHeight: 300, idealHeight: 720, maxHeight: 2304)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .onAppear {
            // The kept choice, before the game's first frame.
            wwvr_visionos_set_window_3d(depth.mirrorWanted)
            let openWindow = openWindow
            // With the launcher's own value: visionOS brings back the one there is.
            model.showLauncher = { openWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID) }
            // Starts the game (or, resumed, carries on) and gives the window the controller.
            model.windowAppeared()
            // Out of the way while you play, as with the immersive spaces; kept when the game didn't
            // start, to say why.
            if model.phase == .running {
                dismissWindow(id: GameModel.launcherWindowID, value: GameModel.launcherWindowID)
            }
        }
        .onDisappear {
            // Closing the window ends the game and the app, or pauses it (Port.windowClosePauses),
            // and the launcher comes back on Play.
            model.windowDisappeared()
        }
        .onChange(of: scenePhase) { _, phase in
            // Hidden or in the background: hold the game clock, as taking the headset off does in
            // the immersive spaces.
            wwvr_visionos_set_paused(phase != .active)
        }
    }
}

/// What the window shows, in window units: 1 wide, its face at z = 0, +z towards the viewer. A
/// portal fills the face and looks into a world holding the mirror and the screen effects' layer;
/// the HUD is a plane just in front of it. Frames are copied in on the main thread (RealityKit's
/// textures and meshes belong to the main actor), on the GPU, after the game's own writes (its
/// MTLSharedEvent).
@MainActor
final class GameScreen {
    let root = Entity()
    var aspectChanged: ((Float) -> Void)?

    private let world = Entity()
    private var portal: ModelEntity
    private var hud: ModelEntity
    // The screen effects (bloom, mist, fades) as a layer over the mirror's world, each part at the
    // depth of what it lies on (the game's depth buffer), so it stays on it from any angle: a
    // character's glow on the character, the sky's in the sky.
    private let effects = ModelEntity()
    // The mirror's level and its blended parts, then the screen effects (when on), then the HUD:
    // drawn in that order, whatever their depths, so nothing of the level nearer than the glass
    // covers the HUD (TPVR).
    private let sortGroup = ModelSortGroup(depthPass: nil)
    private static let effectsOrder: Int32 = MirrorScene.maxBlendedParts + 1
    private var effectsMesh: LowLevelMesh?
    private var effectsGrid = SIMD2<Int>.zero
    private var hudMaterial: ShaderGraphMaterial
    private var effectsMaterial: ShaderGraphMaterial
    private var hudTexture: LowLevelTexture?, effectsTexture: LowLevelTexture?
    private var hudSize = SIMD2<Int>.zero
    private var aspect: Float = 16.0 / 9.0
    private var surfaces: [UInt: MTLTexture] = [:]
    private var surfaceGeneration: UInt64 = .max
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private var frames = 0
    private var mirror: MirrorScene?
    private var mirrorShowing = false
    private let memoryGuard: WindowMemoryGuard
    /// Window frames committed to the GPU and not yet done, for the memory log.
    nonisolated private static let framesInFlight = Atomic<Int>(0)
    private var shownGameFrame: UInt32 = 0
    // 2D or 3D, and what the game was last told (wwvr_visionos_set_window_3d).
    private let depth: WindowDepth
    private var told3D: Bool?
    // How much wider than its picture the game draws in 3D (wwvr_visionos_set_window_view_scale; see
    // MirrorScene.place), from a frame after the game's own frame has faded out; back to 1
    // as soon as 2D is chosen, so the frame that fades in on the way there is the game's own view.
    // (The mirror lays the scene out as the picture is framed whatever the scale: no jump either way.)
    // Test runs: WWVR_TEST_WINDOW_VIEW_SCALE=<scale>; 1 with WWVR_TEST_WINDOW_EFFECTS (the effects'
    // layer samples the drawn frame at the picture's places).
    private static let viewScale: Float = showEffects ? 1 : TestHooks.value("WWVR_TEST_WINDOW_VIEW_SCALE").flatMap(Float.init) ?? 1.5
    private var toldViewScale: Float?
    // The last frame drew the mirror (the 3D path), for WindowDepth's return to 3D, and how flat
    // (WindowDepth.flatFrame) it was drawn, for its way to 2D: encoded, and on the glass (its command
    // buffer completed: the mirror stops only then; stopped once the flat frame was only encoded,
    // the window could show the mirror gone before the frame that hides it).
    private var drewMirror = false
    private var drawnFlat: Float = 1
    nonisolated private static let shownFlat = Atomic<UInt32>(Float(1).bitPattern)
    // WWVR_TEST_WINDOW_DEPTH's switches: (seconds after the launch, mode), in order. (From the
    // launch, not the window's opening, so a script outside can time its screenshots by them.)
    private var depthScript: [(TimeInterval, WindowDepth.Mode)] = (TestHooks.value("WWVR_TEST_WINDOW_DEPTH") ?? "")
        .split(separator: ",").dropFirst().compactMap { item in
            let pair = item.split(separator: "@")
            guard pair.count == 2, let mode = WindowDepth.Mode(rawValue: String(pair[0])),
                  let at = TimeInterval(pair[1]) else { return nil }
            return (at, mode)
        }

    // Test runs: WWVR_TEST_WINDOW_HOLD=<game frame>[+<s>] holds the game's clock once the window
    // shows that game frame and, with +<s>, goes 2D that many seconds later: the mirror (laid flat,
    // WWVR_TEST_WINDOW_FLAT_MIRROR) and then the game's own frame show the same frame, however
    // slowly a busy Mac starts the app or takes the screenshots.
    private var holdFrame: UInt32? = TestHooks.value("WWVR_TEST_WINDOW_HOLD")
        .flatMap { UInt32($0.split(separator: "+").first ?? "") }
    private let holdThen2D: TimeInterval? = TestHooks.value("WWVR_TEST_WINDOW_HOLD")
        .flatMap { $0.split(separator: "+").dropFirst().first.flatMap { TimeInterval($0) } }
    // While held, the last game frame is drawn again each update (no new ones come), so the way to 2D
    // (which mixes in the game's own frame) runs. Its surfaces stay as they are: the game is held.
    private var lastFrame: wwvr_visionos_window_frame?
    private var heldFrame: wwvr_visionos_window_frame?

    private static let rows = 216

    init(depth: WindowDepth) async throws {
        self.depth = depth
        hudMaterial = try await ShaderGraphMaterial(named: "/Root/HudFrame", from: "WindowFrame.usda", in: .main)
        // On the glass, over everything (the sort group): the level comes out nearer than the glass,
        // and depth-tested, the HUD, the fades and the letterbox bars went under it (TPVR).
        hudMaterial.readsDepth = false
        hudMaterial.writesDepth = false
        // Over the whole world, after it (a sort group, below), never depth-tested: tested, it hid
        // behind blended water. What only turns the picture black (a fade's end, letterbox bars)
        // goes on the glass with the HUD instead (WindowHud): on this layer, seen from the side,
        // its farther parts painted over a bar.
        effectsMaterial = hudMaterial
        effectsMaterial.readsDepth = false
        effectsMaterial.writesDepth = false
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CancellationError()
        }
        self.device = device
        self.queue = queue
        memoryGuard = WindowMemoryGuard(device: device)
        pipelines = try Pipelines(device: device)
        world.components.set(WorldComponent())
        portal = ModelEntity()
        hud = ModelEntity()
        root.addChild(world)
        makePlanes(aspect: aspect)
        root.isEnabled = false  // until the first frame
        // Test runs: WWVR_TEST_WINDOW_MIRROR=0 shows the game's frames flat instead.
        if TestHooks.value("WWVR_TEST_WINDOW_MIRROR") != "0" {
            do {
                let mirror = try await MirrorScene()
                mirror.viewScale = Self.viewScale
                world.addChild(mirror.root)
                effects.isEnabled = false
                world.addChild(effects)
                // After every part of the world, translucent ones included: RealityKit's own
                // back-to-front order put the level's translucent parts over a letterbox bar.
                mirror.sort(in: sortGroup, order: 0)
                effects.components.set(ModelSortGroupComponent(group: sortGroup, order: Self.effectsOrder))
                self.mirror = mirror
                wwvr_visionos_set_mirror_enabled(true)
            } catch {
                print("[WWVR] the scene mirror failed to load, so the window shows the game flat: \(error)")
                wwvr_visionos_set_mirror_enabled(false)
            }
        }
        // No mirror: 2D only (the game makes no 3D capture), and no button.
        if mirror == nil { depth.unavailable() }
    }

    /// Window units onto the window: its face is the back of the view's bounds, scaled to its width
    /// in metres. (What the portal's world has nearer than the face still shows, inside the opening.)
    static func fit(_ root: Entity, to bounds: BoundingBox) {
        root.position = [bounds.center.x, bounds.center.y, bounds.min.z]
        root.scale = SIMD3(repeating: bounds.extents.x)
        // Test runs: WWVR_TEST_WINDOW_TILT=<degrees> turns the window about its vertical axis,
        // which shows the depth without moving the Simulator's camera.
        // WWVR_TEST_WINDOW_PITCH=<degrees> about its horizontal axis (its top back: as seen from below).
        let tilt = TestHooks.value("WWVR_TEST_WINDOW_TILT").flatMap(Float.init) ?? 0
        let pitch = TestHooks.value("WWVR_TEST_WINDOW_PITCH").flatMap(Float.init) ?? 0
        if tilt != 0 || pitch != 0 {
            root.orientation = simd_quatf(angle: tilt * .pi / 180, axis: [0, 1, 0]) * simd_quatf(angle: -pitch * .pi / 180, axis: [1, 0, 0])
        }
        if bounds.extents != loggedExtents {
            loggedExtents = bounds.extents
            windowWidth = bounds.extents.x  // the front allowance follows (sendFrontAllowance)
            print(String(format: "[WWVR] window: %.3f x %.3f x %.3f m, from z %.3f to %.3f in the view's scene",
                         bounds.extents.x, bounds.extents.y, bounds.extents.z, bounds.min.z, bounds.max.z))
        }
    }
    private static var loggedExtents = SIMD3<Float>.zero
    private static var windowWidth: Float = 0  // metres
    private var sentAllowance: Float = -1
    /// How far in front of the window the scene may come out (metres). visionOS cuts a plain
    /// window's content off ~0.47 m in front of its face, whatever its size (TPVR, measured at 0.72
    /// and 1.15 m wide; preferredWindowClippingMargins works only for volumes): the mirror cuts what
    /// would come out farther than this, as a near plane cuts (aurora 0111; its glass comes no
    /// farther than the ground at the window's foot, so that ground isn't what's cut, unless that
    /// ground is nearer than a fifth of the focus, the glass's floor).
    private static let frontAllowance: Float = 0.40
    private static let noEase = TestHooks.value("WWVR_TEST_WINDOW_NO_EASE") == "1"

    /// The front allowance the mirror's finish cuts at (window widths): visionOS's limit, less
    /// what the re-aim (MirrorScene.place) can bring farther out. Turning the world level about the
    /// focus brings what lies below the view's axis forward by its height times sin(turn): h, the
    /// drawn half-height at the glass, and less towards the camera's place, c in front of the glass.
    /// What's cut at E in front then comes out at most E + h sin(turn) (1 - E / c), kept within
    /// the limit. (Draws kept past the drawn view, out to twice it, can come out farther: seen only
    /// from steeply below. Reserving for them too, as a7b10cc did, eased the near ground
    /// harder on any window over about a metre.) By Outset's ledge (11.5°) it binds on a window wider than
    /// about 1.3 m, at the 20° cap 1.1 m: the near ground is flatter there.
    private func sendFrontAllowance() {
        guard Self.windowWidth > 0 else { return }
        let full = Self.frontAllowance / max(Self.windowWidth, 0.01)
        var widths = full
        if let mirror, mirror.turnBound > 0, mirror.placedTangents.x > 0 {
            let camera = 1 / (2 * mirror.placedTangents.x)
            let lift = Self.viewScale * mirror.placedTangents.y / (2 * mirror.placedTangents.x) * sin(mirror.turnBound)
            // (The finish cuts nothing with no allowance at all: the least is a hundredth of a width.)
            widths = lift < camera ? min(full, max(0.01, (full - lift) / (1 - lift / camera))) : 0.01
        }
        // Test runs: WWVR_TEST_WINDOW_NO_EASE=1 lets nothing be cut or eased (an allowance of 0):
        // set against the default, what the cut takes (or, with AURORA_MIRROR_NEAR=ease, what the
        // old easing bends).
        if Self.noEase { widths = 0 }
        guard abs(widths - sentAllowance) > 0.002 else { return }
        sentAllowance = widths
        // (0: the camera where its view puts it, as MirrorScene.place lays the scene out.)
        wwvr_visionos_set_mirror_front_allowance(widths, 0)
    }

    func update() {
        switch memoryGuard.check(hasMirror: mirror != nil, mirror: { self.mirror?.diagnostics ?? "off" },
                                 extra: { "\(self.surfaces.count) frame surfaces (\(self.surfaceSizes)), "
                                          + "\(self.frames) window frames, "
                                          + "\(Self.framesInFlight.load(ordering: .relaxed)) in flight" }) {
        case .dropMirror: dropMirror()
        case .quit: wwvr_visionos_request_quit()  // the game returns and the app ends with it (GameModel)
        // The game thread is stuck: exit's teardown could block on it, so the process ends without
        // it. The log line is synced.
        case .forceExit: _exit(0)
        case .none: break
        }
        wwvr_visionos_window_tick()
        // 2D or 3D: the transition's step, and the game and the mirror told when the mirror's
        // wanted or not (in 2D neither does any of the 3D's work).
        if let at = holdFrame, shownGameFrame >= at, shownGameFrame < at &+ 100_000 {
            holdFrame = nil
            wwvr_visionos_set_paused(true)
            heldFrame = lastFrame
            print("[WWVR] window: the game held (WWVR_TEST_WINDOW_HOLD) at frame \(shownGameFrame)")
            if let after = holdThen2D {
                depthScript = [(TestHooks.secondsSinceLaunch() + after, .twoD)]
            }
        }
        if let (at, mode) = depthScript.first, TestHooks.secondsSinceLaunch() >= at {
            depthScript.removeFirst()
            if let held = heldFrame {
                print("[WWVR] window: held game frame \(held.game_frame), mirror frame \(mirror?.shownGameFrame ?? 0)")
            }
            depth.set(mode, persist: false)
        }
        depth.tick(mirrorShowing: drewMirror || mirror == nil, mirrorWhole: mirror?.whole ?? true,
                   flatShown: Float(bitPattern: Self.shownFlat.load(ordering: .relaxed)))
        let viewScale: Float = depth.mode == .threeD && depth.mirrorWanted && depth.flatFrame == 0 ? Self.viewScale : 1
        if toldViewScale != viewScale {
            toldViewScale = viewScale
            wwvr_visionos_set_window_view_scale(viewScale)
        }
        if told3D != depth.mirrorWanted {
            told3D = depth.mirrorWanted
            wwvr_visionos_set_window_3d(depth.mirrorWanted)
            if depth.mirrorWanted { mirror?.resume(after: shownGameFrame) }
            mirror?.root.isEnabled = depth.mirrorWanted
            print("[WWVR] window: \(depth.mirrorWanted ? "3D" : "2D")")
        }
        var frame = wwvr_visionos_window_frame()
        let fresh = wwvr_visionos_window_acquire(&frame)
        if fresh {
            shownGameFrame = frame.game_frame
        }
        // The mirror's frame from the same game frame as the HUD and screen effects shown with it
        // (its frames are ready a little sooner): drawn from different frames, they slid apart.
        // Test runs: WWVR_TEST_WINDOW_FLAT_MIRROR=1 lays the mirror flat on the glass in 3D, where
        // it can be compared pixel for pixel with the game's own frame (WWVR_TEST_WINDOW_DEPTH=2d).
        mirror?.flatten = Self.flatMirror ? 1 : depth.flatten
        mirrorShowing = depth.mirrorWanted ? (mirror?.update(upTo: shownGameFrame) ?? false) : false
        sendFrontAllowance()
        if !fresh, let held = heldFrame, let commands = queue.makeCommandBuffer() {
            _ = encode(held, into: commands, again: true)  // test runs: the held frame again (WWVR_TEST_WINDOW_HOLD)
            let flat = drawnFlat.bitPattern
            commands.addCompletedHandler { _ in Self.shownFlat.store(flat, ordering: .relaxed) }
            commands.commit()
        }
        guard fresh else { return }
        if holdFrame != nil { lastFrame = frame }
        // One the game made as it was being held (frames already on their way) is held instead; the
        // game going on (the scene active again) ends the hold, as its slots are written again.
        if let held = heldFrame {
            heldFrame = frame.game_frame &- held.game_frame <= 2 ? frame : nil
        }
        let serial = frame.serial
        guard let commands = queue.makeCommandBuffer() else {
            wwvr_visionos_window_release(serial)
            return
        }
        commands.label = "Wind Waker VR window frame"
        if let event = frame.event {
            commands.encodeWaitForEvent(Unmanaged<AnyObject>.fromOpaque(event).takeUnretainedValue() as! MTLSharedEvent,
                                        value: frame.value)
        }
        if frame.generation != surfaceGeneration {
            surfaces.removeAll()
            surfaceGeneration = frame.generation
        }
        if encode(frame, into: commands) {
            root.isEnabled = true
        }
        Self.framesInFlight.add(1, ordering: .relaxed)
        let flat = drawnFlat.bitPattern
        commands.addCompletedHandler { _ in
            wwvr_visionos_window_release(serial)
            Self.framesInFlight.subtract(1, ordering: .relaxed)
            Self.shownFlat.store(flat, ordering: .relaxed)
        }
        commands.commit()
        frames += 1
        if frames == 1 || frames % 900 == 0 {
            print("[WWVR] window frame \(frames): scene \(frame.scene != nil), mirror \(mirrorShowing), "
                  + "ui \(frame.ui != nil), tangents \(frame.tan_half_x) x \(frame.tan_half_y), focus \(frame.focus), "
                  + "re-aim \((mirror?.aim ?? 0) * 180 / .pi)°, front allowance \(sentAllowance) widths, "
                  + "effects \(effects.isEnabled)")
        }
    }

    /// The frame surfaces' sizes, for the memory log: they follow the game's internal resolution
    /// (TPVR's at 12x, four slots of them, took Metal past 9 GB: cap it in Window mode).
    private var surfaceSizes: String {
        Set(surfaces.values.map { "\($0.width)x\($0.height)" }).sorted().joined(separator: ", ")
    }

    /// Memory ran away (WindowMemoryGuard): the mirror goes, its textures and meshes with it, and the
    /// window shows the game's own picture, as it does before the mirror's first frame.
    private func dropMirror() {
        wwvr_visionos_set_mirror_enabled(false)
        depth.unavailable()
        mirror?.root.removeFromParent()
        mirror = nil
        mirrorShowing = false
        effects.isEnabled = false
        effects.model = nil
        effectsTexture = nil
        effectsMesh = nil
    }

    // MARK: - One frame

    private func encode(_ frame: wwvr_visionos_window_frame, into commands: MTLCommandBuffer, again: Bool = false) -> Bool {
        guard let final = texture(frame.final, format: .bgra8Unorm_srgb) else { return false }
        let ui = texture(frame.ui, format: .bgra8Unorm_srgb)
        let size = SIMD2(final.width, final.height)
        let frameAspect = Float(size.x) / Float(max(size.y, 1))
        if abs(frameAspect - aspect) > 0.01 {
            aspect = frameAspect
            makePlanes(aspect: aspect)
            aspectChanged?(aspect)
        }
        if size != hudSize, !makeHud(size: size) { return false }
        guard let hudTexture else { return false }
        let hud = hudTexture.replace(using: commands)

        guard mirrorShowing, let mirror,
              let scene = texture(frame.scene, format: .bgra8Unorm_srgb),
              let distance = texture(frame.distance, format: .rgba16Float),
              frame.tan_half_x > 0, frame.tan_half_y > 0 else {
            // No 3D scene (title, loading, films), or no mirror: the whole picture flat on the glass
            // (opaque, so it hides the mirror's last frame).
            pipelines.flat(commands, final: final, ui: ui, hud: hud)
            pipelines.mipmaps(commands, hud)
            effects.isEnabled = false
            drewMirror = false
            drawnFlat = 1
            return true
        }
        drewMirror = true
        drawnFlat = depth.flatFrame
        // The mirror draws the world; the HUD and the screen effects come from the frame. The
        // picture before the effects: what turned black (fades, letterbox bars) is found from it and
        // goes on the glass, with or without the effects' layer.
        let base = texture(frame.base, format: .bgra8Unorm_srgb)
        var layer: MTLTexture?
        if base != nil, let effectsTexture, let effectsMesh, mirror.plane > 0 {
            layer = effectsTexture.replace(using: commands)
            // Laid out as the mirror is: the glass spans the camera's view at the mirror's plane. Its
            // positions change in this command buffer with its texture, so both change together.
            var params = EffectsGridParams(tanHalf: [frame.tan_half_x, frame.tan_half_y], planeDistance: mirror.plane,
                                           columns: UInt32(effectsGrid.x), rows: UInt32(effectsGrid.y), radius: 8,
                                           depthScale: mirror.depthScale)
            pipelines.effectsGrid(commands, distance: distance, params: &params,
                                  positions: effectsMesh.replace(bufferIndex: 0, using: commands))
        }
        pipelines.hud(commands, final: final, scene: scene, base: base, ui: ui, hud: hud, effects: layer,
                      ghost: Self.ghostEffects, flat: depth.flatFrame)
        pipelines.mipmaps(commands, hud)
        effects.isEnabled = layer != nil
        if Self.dumpFrame == frames && !again {
            Self.dump(frame)
        }
        return true
    }

    // The screen effects' layer (bloom, mist, light shafts on a grid draped over the game's depths)
    // is off: from anywhere but the game camera's eye point it came apart from the 3D, a ghost of
    // each figure's glow beside it and streaks fanning back from silhouettes (TPVR, headset). Fades
    // and letterbox bars stay, on the glass. Test runs: WWVR_TEST_WINDOW_EFFECTS=1 brings the
    // layer back; =ghost puts the game's own picture in it at half opacity (one hero if it lines up
    // with the mirror, two if not).
    private static let flatMirror = TestHooks.value("WWVR_TEST_WINDOW_FLAT_MIRROR") == "1"
    private static let showEffects = ["1", "ghost"].contains(TestHooks.value("WWVR_TEST_WINDOW_EFFECTS") ?? "")
    private static let ghostEffects = TestHooks.value("WWVR_TEST_WINDOW_EFFECTS") == "ghost"

    // Test runs: WWVR_TEST_WINDOW_DUMP=<frame> writes that frame's scene, finished frame and
    // pre-effects scene (BGRA8) and distances (RGBA16F) raw into Documents, named with their sizes
    // (scripts/window-dump.py turns them into PNGs and the effects layer).
    private static let dumpFrame = TestHooks.value("WWVR_TEST_WINDOW_DUMP").flatMap(Int.init) ?? -1

    private static func dump(_ frame: wwvr_visionos_window_frame) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for (name, pointer) in [("scene", frame.scene), ("distance", frame.distance), ("final", frame.final),
                                ("base", frame.base)] {
            guard let pointer else { continue }
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            IOSurfaceLock(surface, .readOnly, nil)
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            let rowBytes = IOSurfaceGetBytesPerRow(surface), element = IOSurfaceGetBytesPerElement(surface)
            var data = Data(capacity: width * height * element)
            let base = IOSurfaceGetBaseAddress(surface)
            for row in 0..<height {
                data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * element)
            }
            IOSurfaceUnlock(surface, .readOnly, nil)
            try? data.write(to: documents.appendingPathComponent("window-\(name)-\(width)x\(height).raw"))
        }
        print("[WWVR] window frame dumped: tangents \(frame.tan_half_x) x \(frame.tan_half_y), focus \(frame.focus)")
    }

    /// A Metal texture over one of the game's IOSurfaces, made once per surface.
    private func texture(_ pointer: UnsafeMutableRawPointer?, format: MTLPixelFormat) -> MTLTexture? {
        guard let pointer else { return nil }
        let key = UInt(bitPattern: pointer)
        if let cached = surfaces[key] { return cached }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        surfaces[key] = texture
        return texture
    }

    // MARK: - Scene objects

    private func makePlanes(aspect: Float) {
        portal.removeFromParent()
        hud.removeFromParent()
        let height = 1 / aspect
        portal = ModelEntity(mesh: .generatePlane(width: 1, height: height), materials: [PortalMaterial()])
        // Not clipped at the glass (as in the SHAR port): what the mirror has nearer than the glass
        // (a pitched-down camera's ground) comes out in front of it, inside the window's opening, as
        // the shape it is, cut at frontAllowance. Clipped there, it had to be squashed into a
        // band behind the glass, which bent TPVR's ground near the camera.
        portal.components.set(PortalComponent(target: world))
        // The whole face is a target for pinches and taps (GameWindowView's gesture), so they stop here.
        portal.components.set(InputTargetComponent())
        portal.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: height, depth: 0.004)]))
        hud = ModelEntity(mesh: .generatePlane(width: 1, height: height), materials: [hudMaterial])
        // In the portal's world, on the glass, last in the sort group (which orders only what's in
        // the same world).
        hud.position.z = -0.0005
        hud.components.set(ModelSortGroupComponent(group: sortGroup, order: Self.effectsOrder + 1))
        root.addChild(portal)
        world.addChild(hud)
    }

    private func makeHud(size: SIMD2<Int>) -> Bool {
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                    textureUsage: [.shaderRead, .shaderWrite])
        // The HUD with mipmaps, made by the GPU each frame (Pipelines.mipmaps): written at the game's
        // resolution and shown on a window covering fewer pixels, its text and menus sparkled, worst
        // with the window small, far off or at an angle (TPVR, SHAR). Premultiplied, so edges stay clean.
        let hudDescriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: size.x, height: size.y,
                                                       mipmapLevelCount: Int(log2(Double(max(size.x, size.y)))) + 1,
                                                       textureUsage: [.shaderRead, .shaderWrite, .renderTarget])
        guard let texture = try? LowLevelTexture(descriptor: hudDescriptor),
              let resource = try? TextureResource(from: texture) else {
            print("[WWVR] the window's \(size.x)x\(size.y) HUD texture failed")
            return false
        }
        try? hudMaterial.setParameter(name: "Frame", value: .textureResource(resource))
        hud.model?.materials = [hudMaterial]
        hudTexture = texture
        hudSize = size
        let rows = Self.rows
        let columns = max(16, Int((Float(rows) * Float(size.x) / Float(max(size.y, 1))).rounded()))
        if mirror != nil, Self.showEffects, let layer = try? LowLevelTexture(descriptor: descriptor),
           let layerResource = try? TextureResource(from: layer),
           let mesh = try? Self.makeGridMesh(columns: columns, rows: rows),
           let meshResource = try? MeshResource(from: mesh) {
            try? effectsMaterial.setParameter(name: "Frame", value: .textureResource(layerResource))
            effects.model = ModelComponent(mesh: meshResource, materials: [effectsMaterial])
            effectsTexture = layer
            effectsMesh = mesh
            effectsGrid = [columns, rows]
        } else {
            effectsTexture = nil
            effectsMesh = nil
        }
        return true
    }

    /// The screen effects' layer: (columns + 1) x (rows + 1) vertices over the picture, positions from
    /// the GPU each frame, UVs fixed.
    private static func makeGridMesh(columns: Int, rows: Int) throws -> LowLevelMesh {
        let across = columns + 1, down = rows + 1
        let indexCount = columns * rows * 6
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: across * down,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 12), .init(bufferIndex: 1, bufferStride: 8)],
            indexCapacity: indexCount, indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for row in 0..<down {
                for column in 0..<across {
                    uvs[row * across + column] = [Float(column) / Float(columns), 1 - Float(row) / Float(rows)]
                }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    // Two counter-clockwise triangles, facing the viewer.
                    let topLeft = UInt32(row * across + column), bottomLeft = topLeft + UInt32(across)
                    for index in [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        // Generous bounds, in window units: tight ones (still enclosing every vertex) blacked out the
        // whole window, HUD and all, in the Simulator (TPVR).
        let bounds = BoundingBox(min: [-60, -40, -60], max: [60, 40, 1])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)])
        return mesh
    }
}

private struct EffectsGridParams {
    var tanHalf: SIMD2<Float>
    var planeDistance: Float
    var columns: UInt32
    var rows: UInt32
    var radius: UInt32
    var depthScale: Float
}

private struct HudFlags {
    var hasUi: UInt32
    var hasBase: UInt32
    var ghost: UInt32
    var writeEffects: UInt32
    var flat: Float  // WindowDepth.flatFrame: how much of the game's own frame covers the mirror
}

/// The window's Metal kernels (from the TPVR and SHAR ports).
@MainActor
private struct Pipelines {
    let hud, flat, effectsGrid: MTLComputePipelineState

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw CancellationError() }
            return try device.makeComputePipelineState(function: function)
        }
        hud = try make("WindowHud")
        flat = try make("WindowFlat")
        effectsGrid = try make("WindowEffectsGrid")
    }

    /// The HUD (`ui`, the game's 2D as its own layer) over the scene, and (given `base`, the scene
    /// before the screen effects, and an `effects` target) what those effects did to it.
    func hud(_ commands: MTLCommandBuffer, final: MTLTexture, scene: MTLTexture, base: MTLTexture?, ui: MTLTexture?,
             hud: MTLTexture, effects: MTLTexture?, ghost: Bool = false, flat: Float = 0) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        var flags = HudFlags(hasUi: ui != nil ? 1 : 0, hasBase: base != nil ? 1 : 0, ghost: ghost ? 1 : 0,
                             writeEffects: base != nil && effects != nil ? 1 : 0, flat: flat)
        compute.setComputePipelineState(self.hud)
        compute.setTexture(final, index: 0)
        compute.setTexture(scene, index: 1)
        compute.setTexture(ui ?? final, index: 2)
        compute.setTexture(hud, index: 3)
        compute.setTexture(base ?? scene, index: 4)
        compute.setTexture(effects ?? hud, index: 5)
        compute.setBytes(&flags, length: MemoryLayout<HudFlags>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: hud.width, height: hud.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    /// The rest of `texture`'s mipmaps from its level 0.
    func mipmaps(_ commands: MTLCommandBuffer, _ texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
    }

    func effectsGrid(_ commands: MTLCommandBuffer, distance: MTLTexture, params: inout EffectsGridParams,
                     positions: MTLBuffer) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(effectsGrid)
        compute.setTexture(distance, index: 0)
        compute.setBuffer(positions, offset: 0, index: 0)
        compute.setBytes(&params, length: MemoryLayout<EffectsGridParams>.stride, index: 1)
        compute.dispatchThreads(MTLSize(width: Int(params.columns) + 1, height: Int(params.rows) + 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    func flat(_ commands: MTLCommandBuffer, final: MTLTexture, ui: MTLTexture?, hud: MTLTexture) {
        guard let compute = commands.makeComputeCommandEncoder() else { return }
        var hasUi: UInt32 = ui != nil ? 1 : 0
        compute.setComputePipelineState(flat)
        compute.setTexture(final, index: 0)
        compute.setTexture(ui ?? final, index: 1)
        compute.setTexture(hud, index: 2)
        compute.setBytes(&hasUi, length: 4, index: 0)
        compute.dispatchThreads(MTLSize(width: hud.width, height: hud.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Premultiplied `over`.
    static float4 Over(float4 top, float4 under) { return top + under * (1.0 - top.a); }

    // The screen effects (bloom, mist, light shafts, fades, letterbox bars): what they did to the
    // game's 3D picture, as a premultiplied layer over the window's own 3D. The picture went from
    // `before` to `after`; as `after = before * (1 - a) + e` the layer takes the least cover `a`
    // that leaves `e` no darker than black, so a glow only adds light, a fade only covers, and from
    // straight ahead the window matches the game exactly. (Linear values: the views are sRGB.)
    static float4 Effects(float3 after, float3 before)
    {
        if (all(after == before)) return float4(0);
        if (all(after < 1e-4)) return float4(0, 0, 0, 1);  // black: a fade's end, letterbox bars
        // Darkening within a step or two of 8-bit noise doesn't count as cover.
        const float3 slack = 0.004 + 0.02 * after;
        const float3 kept = (after + slack) / max(before, 1e-4);
        const float a = saturate(1.0 - min(min(kept.r, kept.g), kept.b));
        return float4(max(after - before * (1.0 - a), 0.0), a);
    }

    // A pixel the HUD changed, as the least cover `a` and premultiplied colour `c` that explain it:
    // after = before * (1 - a) + c. A translucent panel or a soft glow then keeps the window's own 3D
    // under it, as the game's scene was, rather than the scene as the game's camera saw it pinned
    // opaque to the glass (TPVR's bright halos behind its menus); an opaque pixel comes out opaque.
    static float4 HudCover(float3 before, float3 after)
    {
        float a = 0.0;
        for (int i = 0; i < 3; ++i)
        {
            if (after[i] > before[i]) a = max(a, (after[i] - before[i]) / max(1.0 - before[i], 1e-4));
            else if (after[i] < before[i]) a = max(a, (before[i] - after[i]) / max(before[i], 1e-4));
        }
        a = saturate(a);
        return float4(clamp(after - before * (1.0 - a), 0.0, a), a);
    }

    struct HudFlags { uint hasUi, hasBase, ghost, writeEffects; float flat; };

    struct EffectsGridParams { float2 tanHalf; float planeDistance; uint columns, rows, radius; float depthScale; };

    // The screen effects' layer, laid out as the scene mirror is (the glass spans the camera's view
    // at planeDistance, depths times depthScale): each vertex at the nearest distance within
    // `radius` pixels, so a glow just outside a figure stays on the figure; never in front of the
    // glass. One plane at the camera's focus isn't enough: the focus point sat ~12% in front of
    // TPVR's hero, and from the side the layer's copy of him slid off the mirror's.
    kernel void WindowEffectsGrid(texture2d<float, access::read> distance [[texture(0)]],
                                  device packed_float3* positions [[buffer(0)]],
                                  constant EffectsGridParams& p [[buffer(1)]],
                                  uint2 id [[thread_position_in_grid]])
    {
        if (id.x > p.columns || id.y > p.rows) return;
        const float u = float(id.x) / float(p.columns), v = float(id.y) / float(p.rows);
        const int2 size = int2(distance.get_width(), distance.get_height());
        const int2 centre = int2(float2(u, v) * float2(size));
        const int r = int(p.radius), step = max(1, r / 2);
        float nearest = 1e9;
        for (int dy = -r; dy <= r; dy += step)
        {
            for (int dx = -r; dx <= r; dx += step)
            {
                const int2 at = clamp(centre + int2(dx, dy), int2(0), size - 1);
                nearest = min(nearest, distance.read(uint2(at)).r);
            }
        }
        // A hair behind the glass at the least (the layer isn't cut at the front allowance as the mirror is).
        nearest = clamp(nearest, p.planeDistance * 1.0005, 60000.0);
        const float tanX = mix(-p.tanHalf.x, p.tanHalf.x, u), tanY = mix(p.tanHalf.y, -p.tanHalf.y, v);
        const float scale = 1.0 / (2.0 * p.planeDistance * p.tanHalf.x);
        positions[id.y * (p.columns + 1) + id.x] = packed_float3(scale * tanX * nearest, scale * tanY * nearest,
                                                                 scale * p.depthScale * (p.planeDistance - nearest));
    }

    // The HUD over what turned black (letterbox bars, a fade's end). On a frame with a 3D scene the
    // game hands its 2D as a layer of its own (`ui`, premultiplied: wwvr_window_hud_*), and its
    // finished frame is the scene, so nothing differs for HudCover to find. (Found from the finished
    // frame as the least cover that explains each changed pixel, a translucent panel kept part of the
    // game's flat 3D picture, which showed through the HUD over the mirror's.) With the effects'
    // layer on, the other screen effects go to it.
    kernel void WindowHud(texture2d<float, access::read> final [[texture(0)]],
                          texture2d<float, access::read> scene [[texture(1)]],
                          texture2d<float, access::read> ui [[texture(2)]],
                          texture2d<float, access::write> hud [[texture(3)]],
                          texture2d<float, access::read> base [[texture(4)]],
                          texture2d<float, access::write> effects [[texture(5)]],
                          constant HudFlags& flags [[buffer(0)]],
                          uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
        const float4 drawn = final.read(id), under = scene.read(id);
        const bool changed = any(abs(drawn.rgb - under.rgb) > 0.004);
        float4 glass = float4(0);  // what covers the glass under the HUD
        if (flags.hasBase != 0)
        {
            const uint2 at = uint2(float2(id) * float2(base.get_width(), base.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            float4 effect = flags.ghost != 0 ? float4(under.rgb * 0.5, 0.5) : Effects(under.rgb, base.read(at).rgb);
            // What turns black (letterbox bars, a fade's end) covers the window itself, on the glass.
            // Only that: a depth of field darkening dark rocks behind a face, laid on the glass,
            // covered half the face from the side (TPVR); a partial fade is the same at any depth.
            if (flags.ghost == 0 && effect.a > 0.999 && all(effect.rgb < 0.0005))
            {
                glass = float4(0, 0, 0, effect.a);
                effect = float4(0);
            }
            // The effects' own layer, when it's on; the black above goes on the glass either way.
            if (flags.writeEffects != 0) effects.write(effect, id);
        }
        // The HUD the game drew over that: over black, exactly the game's pixel.
        float4 colour = changed ? Over(HudCover(under.rgb, drawn.rgb), glass) : glass;
        if (flags.hasUi != 0)
        {
            const uint2 at = uint2(float2(id) * float2(ui.get_width(), ui.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            colour = Over(ui.read(at), colour);
        }
        // Going to or from 2D: the game's own frame (its scene and HUD, opaque) over the mirror by
        // `flat` (premultiplied, so a straight mix).
        if (flags.flat > 0.0)
        {
            float4 picture = float4(drawn.rgb, 1);
            if (flags.hasUi != 0)
            {
                const uint2 at = uint2(float2(id) * float2(ui.get_width(), ui.get_height()) /
                                       float2(hud.get_width(), hud.get_height()));
                picture = Over(ui.read(at), picture);
            }
            colour = mix(colour, picture, flags.flat);
        }
        hud.write(colour, id);
    }

    // No 3D scene (title, loading, films): the whole picture, flat on the glass.
    kernel void WindowFlat(texture2d<float, access::read> final [[texture(0)]],
                           texture2d<float, access::read> ui [[texture(1)]],
                           texture2d<float, access::write> hud [[texture(2)]],
                           constant uint& hasUi [[buffer(0)]],
                           uint2 id [[thread_position_in_grid]])
    {
        if (id.x >= hud.get_width() || id.y >= hud.get_height()) return;
        float4 colour = float4(final.read(id).rgb, 1);
        if (hasUi != 0)
        {
            const uint2 at = uint2(float2(id) * float2(ui.get_width(), ui.get_height()) /
                                   float2(hud.get_width(), hud.get_height()));
            colour = Over(ui.read(at), colour);
        }
        hud.write(colour, id);
    }
    """
}
