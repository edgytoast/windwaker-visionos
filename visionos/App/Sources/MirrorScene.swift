@preconcurrency import Metal
import QuartzCore
import RealityKit
import Synchronization

/// The window's scene mirror: the game's own 3D draws, rebuilt each frame as one RealityKit mesh,
/// so RealityKit renders the game's world from the viewer's real eyes and the window shows it from
/// any angle, with nothing to fill in behind the hero however far you lean. The approach is the
/// SHAR port's; this file is the TPVR port's (visionos/App/Sources/MirrorScene.swift), fed by
/// host/scene_mirror.h: vertices in the camera's view space, each draw's material reduced to
/// texture x colour + colour per vertex, textures as RGBA.
///
/// One mesh with a part per solid material, refilled each frame (RealityKit's cost is in refilling a
/// mesh, not in its size: SHAR measured ~0.14 ms a mesh, so one per draw capped it at 45 Hz), and
/// each blended part in an entity of its own, in the game's order. It sits in the portal's world,
/// placed so the game's camera is where a viewer's eye would be for the picture to be exact: the
/// window spans the camera's view a little short of its focus.
@MainActor
final class MirrorScene {
    let root = Entity()
    private let entity = ModelEntity()
    // Behind everything: where the game drew nothing the mirror can show (past the edges of its
    // view, seen from the side), black, as the game's own picture is, not the room.
    private let backdrop = ModelEntity(mesh: .generatePlane(width: 1, height: 1),
                                       materials: [UnlitMaterial(color: .black)])
    // The level's two meshes, each frame filling the one not on screen (its vertices, indices and
    // parts) before the entity swaps to it; and in each, every solid part's indices in a region of
    // their own, at the same place from frame to frame (`regions`). RealityKit can draw a mesh's
    // new parts with its previous indices, or the other way about: laid end to end, the parts'
    // ranges moved every frame (a part's count changes, and every part after it moves), and a
    // close-up part's last triangles were drawn with its neighbour's, or not at all, changing from
    // frame to frame (TPVR's see-through stone). In a region of its own a part reads its own
    // triangles, a frame old at worst; the rest of a region holds empty triangles. A mesh's resource
    // is made only once it has its parts: made before then, RealityKit sometimes never drew it.
    // (TPVR's 67acc4be78, 6b3a06b398 and ee2014af50; filling the mesh not on screen also halved an
    // update's cost there.)
    private struct LevelMesh {
        let mesh: LowLevelMesh
        var resource: MeshResource?
        var regions: [RegionKey: Region] = [:]
        var regionsEnd = 0
    }
    private struct RegionKey: Hashable {
        let key: MaterialKey
        let occurrence: Int
    }
    private struct Region {
        let offset: Int, capacity: Int
    }
    private var levelMeshes: [LevelMesh?] = [nil, nil]
    private var shownMesh = 1  // the one the entity draws; the other is filled next
    private var shownResource: MeshResource?
    // The most the level has needed lately (this 10 s and the last), for sizing its meshes down
    // again after a big frame: their room only ever grew, and past about 3.2 MB of vertices every
    // fill costs RealityKit 12 to 15 ms instead of 0.3 (TPVR).
    private var peak = (vertices: 0, indices: 0, previousVertices: 0, previousIndices: 0, since: CACurrentMediaTime())
    // Test runs: WWVR_TEST_MIRROR_ONE_LEVEL_MESH=1 fills the one on screen.
    private static let oneLevelMesh = TestHooks.value("WWVR_TEST_MIRROR_ONE_LEVEL_MESH") == "1"
    private let queue: MTLCommandQueue
    // Blended parts, each in an entity of its own in the window's sort group, in the game's order
    // (as the SHAR port does). In the one mesh, all with the frame's bounds, RealityKit ordered them
    // itself, by distance from the eye: layered ones (the sky's, the ground's second passes, a
    // horse's dust) took turns as the head moved, and flickered (TPVR).
    @MainActor private final class BlendSlot {
        let entity = ModelEntity()
        var mesh: LowLevelMesh?
        var material: MaterialKey?
        var order: Int32 = .min
    }
    private var blendSlots: [BlendSlot] = []
    private var sortGroup: ModelSortGroup?
    private var sortOrder: Int32 = 0
    private var remap: [Int32] = []  // a frame vertex's index in the slot being filled, -1 when none

    // MirrorMaterials(Wrap).usda: kind ("Opaque", "Cutout", "Blend") + wrap ("RR", "CC"...).
    private var templates: [String: ShaderGraphMaterial] = [:]
    private var textures: [UInt64: TextureResource] = [:]
    // Their textures, for the ones the game updates (shadows read back each frame).
    private var lowLevelTextures: [UInt64: LowLevelTexture] = [:]
    private var failedTextures: Set<UInt64> = []
    private struct PendingTexture { let id: UInt64; let pixels: Data; let width: Int; let height: Int; let mipmapped: Bool; let cutout: Bool }
    private var pendingTextures: [PendingTexture] = []
    private var wantedTextures: Set<UInt64> = []
    private var texturesArrived = false
    // Textures the game let go of (unused for 15 s), kept with their materials, in the order they
    // went: one that comes back (an area returned to, a menu closed) has the id it had and finds
    // them as they were. Dropped, its return added a material to the level's list and set the list
    // again, which can cost the renderer a frame of the whole level: TPVR flashed for minutes after
    // a load. Up to parkedBudget bytes; past it, the longest gone go for good.
    private var parked: [UInt64] = []
    private var parkedSet: Set<UInt64> = []
    private static let parkedBudget = 48 << 20
    private var white: TextureResource?
    private var materials: [MaterialKey: ShaderGraphMaterial] = [:]
    // The entity's material list, which the solid parts index; it grows as materials appear, and is
    // set again only then (setting it may cost RealityKit's renderer a frame).
    private var materialList: [MaterialKey] = []
    private var materialIndex: [MaterialKey: Int] = [:]
    private var materialReady: [Bool] = []
    private var serial: UInt64 = 0
    private(set) var hasScene = false
    /// How far the scene is laid flat on the glass (WindowDepth.flatten): 0 at full depth, 1 flat,
    /// each point moved along its own line of sight. Applied as the mesh is filled; a change refills
    /// the frame shown.
    var flatten: Float = 0
    private var filledFlatten: Float = 0
    // After resume(): no frame shows until one made since (a game frame after `resumedAfter`).
    private var awaitingFresh = false
    private var resumedAfter: UInt32 = 0
    /// The frame last filled had no part left out waiting for its texture.
    private(set) var whole = false
    /// The view distance the glass is at (game units), as last placed.
    private(set) var plane: Float = 1
    /// How much depths are scaled (MirrorScene.place): 1, every shape in its own proportions.
    private(set) var depthScale: Float = 1
    /// How much of the game camera's downward pitch the window takes out, turning its world about the
    /// focus (MirrorScene.place): the fraction, at most the cap. Test runs:
    /// WWVR_TEST_WINDOW_REAIM=<fraction>[,<cap degrees>[,<degrees more, looking down at the window>]].
    private static let reaim: (fraction: Float, cap: Float, extra: Float) = {
        let values = (TestHooks.value("WWVR_TEST_WINDOW_REAIM") ?? "").split(separator: ",").compactMap { Float($0) }
        // The effects test layer (WWVR_TEST_WINDOW_EFFECTS) isn't turned with the world: none with it.
        let effects = ["1", "ghost"].contains(TestHooks.value("WWVR_TEST_WINDOW_EFFECTS") ?? "")
        return (values.first ?? (effects ? 0 : 1), (values.count > 1 ? values[1] : 20) * .pi / 180, (values.count > 2 ? values[2] : 0) * .pi / 180)
    }()
    /// How high the eye is raised (MirrorScene.place), as a fraction of the game camera's own height
    /// above the focus: 1 levels the view about the camera's place rather than Link's. This variant
    /// (branch raise-half, for Trevor to compare with 1): half, Link's head mid-window as in the
    /// game's own 2D at Outset's ledge. Test runs: WWVR_TEST_WINDOW_RAISE=<fraction>.
    private static let raise: Float = TestHooks.value("WWVR_TEST_WINDOW_RAISE").flatMap(Float.init) ?? 0.5
    private var framePitch: Float = 0        // the newest frame's camera pitch (radians; 0 in first person, events)
    private var cutSincePlaced = false       // the camera cut in a frame taken since the last place
    /// The turn as last placed (radians), eased toward the wanted.
    private(set) var aim: Float = 0
    /// The picture's tangents as last placed, and the most the turn may be soon (the larger of the
    /// one placed and the one it eases toward): GameScreen's front allowance makes room for it.
    private(set) var placedTangents = SIMD2<Float>(0, 0)
    private(set) var turnBound: Float = 0
    /// How much wider than its picture the game draws in 3D (GameScreen.viewScale).
    var viewScale: Float = 1.5
    private var lastFocus: Float = 0
    private var aimTime: CFTimeInterval = 0
    private static let cullTest = TestHooks.value("WWVR_TEST_MIRROR_CULL") ?? ""
    private static let addRed = TestHooks.value("WWVR_TEST_MIRROR_ADD_RED") == "1"

    private var timing = (updates: 0, frames: 0, seconds: 0.0, since: CACurrentMediaTime(), vertices: 0, parts: 0, drawn: 0,
                          total: 0)
    private var counts = (texturesMade: 0, texturesFailed: 0, materialSets: 0, meshesMade: 0, fills: 0, cuts: 0)
    // Of an update's time: filling the mesh, and setting its parts (where RealityKit waits for its
    // renderer: a mesh with more vertex attributes doubled it).
    private var stages = (fill: 0.0, parts: 0.0, slots: 0.0)

    private struct MaterialKey: Hashable {
        var texture: UInt64
        var kind: UInt32
        var wrap: String
        var flags: UInt32
        var cutoff: UInt8
        var weights: SIMD8<Int8>

        init(_ part: wwvr_visionos_mirror_part) {
            texture = part.texture
            kind = part.kind
            let letter = { (mode: UInt8) in mode == UInt8(WWVR_VISIONOS_MIRROR_WRAP_CLAMP) ? "C" : mode == UInt8(WWVR_VISIONOS_MIRROR_WRAP_MIRROR) ? "M" : "R" }
            wrap = letter(part.wrap_s) + letter(part.wrap_t)
            flags = part.flags & (WWVR_VISIONOS_MIRROR_CULL_BACK | WWVR_VISIONOS_MIRROR_CULL_FRONT | WWVR_VISIONOS_MIRROR_DEPTH_WRITE | WWVR_VISIONOS_MIRROR_DEPTH_TEST
                                  | WWVR_VISIONOS_MIRROR_BACKGROUND)
            cutoff = part.kind == WWVR_VISIONOS_MIRROR_PART_CUTOUT ? UInt8(clamping: Int((part.cutoff * 255).rounded())) : 0
            let quantise = { (value: Float) in Int8(clamping: Int((value * 16).rounded())) }
            weights = part.kind == WWVR_VISIONOS_MIRROR_PART_BLEND
                ? SIMD8(quantise(part.colour_base), quantise(part.colour_alpha), quantise(part.opacity_base),
                        quantise(part.opacity_alpha), quantise(part.opacity_luma), 0, 0, 0)
                : .zero
        }
    }

    init() async throws {
        guard let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue() else { throw CancellationError() }
        self.queue = queue
        // The game works out where the window's foot meets the ground with the same re-aim (the
        // sill: the glass comes no farther; aurora 0111).
        wwvr_visionos_set_window_aim(Self.reaim.fraction, Self.reaim.cap, Self.raise, Self.reaim.extra)
        for kind in ["Opaque", "Cutout", "Blend"] {
            templates[kind + "RR"] = try await ShaderGraphMaterial(named: "/Root/Mirror\(kind)_RR", from: "MirrorMaterials.usda", in: .main)
        }
        // The other wrap modes, separately: without them, textures repeat.
        do {
            for wrap in ["RC", "RM", "CR", "CC", "CM", "MR", "MC", "MM"] {
                for kind in ["Opaque", "Cutout", "Blend"] {
                    templates[kind + wrap] = try await ShaderGraphMaterial(
                        named: "/Root/Mirror\(kind)_\(wrap)", from: "MirrorMaterialsWrap.usda", in: .main)
                }
            }
        } catch {
            print("[WWVR] mirror: clamped and mirrored texture materials failed to load, so they repeat: \(error)")
        }
        white = Self.makeTexture(queue: queue, pixels: [255, 255, 255, 255], width: 1, height: 1)
        entity.isEnabled = false
        root.addChild(entity)
        backdrop.isEnabled = false
        root.addChild(backdrop)
    }

    /// Draws the level as `order` in `group`, its blended parts after it in the game's order, the
    /// background (the sky's parts, drawn by the game before anything wrote depth) before it in the
    /// game's order, and the backdrop first; what the window lays over the level goes from `order` +
    /// 1 + maxBlendedParts. The backdrop must be in the group too: left out, RealityKit drew it after
    /// the level now and then (one Simulator launch in five or so) and, as the group's models don't
    /// settle depth against what's outside it, it covered the whole level.
    func sort(in group: ModelSortGroup, order: Int32) {
        backdrop.components.set(ModelSortGroupComponent(group: group, order: order - Self.maxBlendedParts - 1))
        entity.components.set(ModelSortGroupComponent(group: group, order: order))
        sortGroup = group
        sortOrder = order
        for slot in blendSlots { slot.order = .min }
    }
    static let maxBlendedParts: Int32 = 1 << 16
    // Test runs: WWVR_TEST_MIRROR_ONE_MESH=1 keeps the blended parts in the one mesh.
    private static let oneMesh = TestHooks.value("WWVR_TEST_MIRROR_ONE_MESH") == "1"

    /// The game frame the newest frame taken was made from (test runs compare it with the game's own).
    private(set) var shownGameFrame: UInt32 = 0

    /// Takes the game's newest mirror frame no later than game frame `upTo` (the window frame shown
    /// with it) into the mesh. False while there's no 3D scene to show (the window then shows the
    /// game's flat picture).
    func update(upTo: UInt32) -> Bool {
        let start = CACurrentMediaTime()
        defer { report(start) }
        var frame = wwvr_visionos_mirror_frame()
        guard wwvr_visionos_mirror_acquire(&frame, upTo) else { return false }
        takeTextures(frame, start: start)
        // The same frame again only to lay it flatter or deeper (WindowDepth's transition).
        let fresh = frame.serial != serial
        guard fresh || (hasScene && !awaitingFresh && flatten != filledFlatten) else { return hasScene && !awaitingFresh }
        if fresh {
            serial = frame.serial
            shownGameFrame = frame.game_frame
            // (A pitch not known, NaN, a frame older than the host's record of them, keeps the last.)
            if !frame.pitch.isNaN { framePitch = frame.pitch }
            cutSincePlaced = cutSincePlaced || frame.cut
            // A frame finished before the mirror stopped may still be the newest: not that one.
            if awaitingFresh && !Self.notAfter(frame.game_frame, resumedAfter) { awaitingFresh = false }
            timing.frames += 1
            timing.total += 1
        }
        guard !awaitingFresh else { return false }
        filledFlatten = flatten
        guard frame.scene, frame.index_count > 0, frame.part_count > 0, frame.tan_half_x > 0,
              let vertices = frame.vertices, let indices = frame.indices, let parts = frame.parts else {
            entity.isEnabled = false
            backdrop.isEnabled = false
            for slot in blendSlots { slot.entity.isEnabled = false }
            hasScene = false
            whole = false
            return false
        }
        last = (Int(frame.vertex_count), Int(frame.index_count), Int(frame.part_count), last.blended)
        let keys = (0..<Int(frame.part_count)).map { MaterialKey(parts[$0]) }
        // Slots of their own: blended parts, and the background's (the sky: drawn first, in the game's
        // order, as the game does, under everything).
        let inSlot = { (index: Int) in
            (parts[index].kind == WWVR_VISIONOS_MIRROR_PART_BLEND || parts[index].flags & WWVR_VISIONOS_MIRROR_BACKGROUND != 0)
                && !Self.oneMesh
        }
        // The level's list holds the solid parts' materials only: a new particle's doesn't set it.
        updateMaterials((0..<keys.count).filter { !inSlot($0) }.map { keys[$0] })
        var low = SIMD3(frame.bounds_min.0, frame.bounds_min.1, frame.bounds_min.2)
        var high = SIMD3(frame.bounds_max.0, frame.bounds_max.1, frame.bounds_max.2)
        if flatten > 0 { (low, high) = Self.withGlass(low, high, frame) }
        let pad = (high - low) * 0.05 + 1
        let bounds = BoundingBox(min: low - pad, max: high + pad)
        // A part whose texture is still on its way waits: drawn white, it flashed.
        // The solid parts in the level's mesh; each blended one in a slot of its own (fillBlend).
        var solidParts: [(index: Int, materialIndex: Int)] = []
        var blendedParts: [(index: Int, material: ShaderGraphMaterial, order: Int32)] = []
        var backgroundCount: Int32 = 0, blendCount: Int32 = 0
        for index in 0..<Int(frame.part_count) {
            if inSlot(index) {
                if let material = material(for: keys[index]) {
                    if blendedParts.count < Int(Self.maxBlendedParts) {
                        // The background before the level, the blends after it, each in the game's order.
                        let background = parts[index].flags & WWVR_VISIONOS_MIRROR_BACKGROUND != 0
                        let order = background ? sortOrder - Self.maxBlendedParts + backgroundCount : sortOrder + 1 + blendCount
                        if background { backgroundCount += 1 } else { blendCount += 1 }
                        blendedParts.append((index, material, order))
                    }
                } else {
                    wantedTextures.insert(keys[index].texture)
                }
                continue
            }
            guard let materialIndex = materialIndex[keys[index]], materialReady[materialIndex] else {
                wantedTextures.insert(keys[index].texture)
                continue
            }
            solidParts.append((index, materialIndex))
        }
        whole = wantedTextures.isEmpty
        let fillStart = CACurrentMediaTime()
        let filled = fill(vertices: vertices, vertexCount: Int(frame.vertex_count), indices: indices, parts: parts,
                          keys: keys, solid: solidParts, bounds: bounds, plane: max(frame.plane, 1e-3))
        stages.fill += CACurrentMediaTime() - fillStart
        guard let (filledIndex, drawn) = filled, let mesh = levelMeshes[filledIndex]?.mesh else { return hasScene }
        let partsStart = CACurrentMediaTime()
        mesh.parts.replaceAll(drawn)
        let levelShown = show(filledIndex, hasParts: !drawn.isEmpty)
        let slotsStart = CACurrentMediaTime()
        stages.parts += slotsStart - partsStart
        defer { stages.slots += CACurrentMediaTime() - slotsStart }
        fillSlots(blendedParts, parts: parts, keys: keys, vertices: vertices, vertexCount: Int(frame.vertex_count),
                  indices: indices, frame: frame)
        timing.drawn += drawn.count + last.blended
        place(frame)
        if Self.dumpFrame == timing.total {
            dump(frame)
        }
        entity.isEnabled = levelShown
        backdrop.isEnabled = true
        hasScene = true
        timing.vertices += Int(frame.vertex_count)
        timing.parts += Int(frame.part_count)
        return true
    }

    /// View space into window units, the same scale every way: the window spans the camera's view at
    /// the frame's `plane` (a little short of its focus, nothing nearer), so the camera sits
    /// 1 / (2 tan) window widths in front of the glass, and from anywhere Link, a face, a pot keep
    /// their shapes and both eyes agree on them. (142fd31 scaled depths by 2 tan D to put the camera
    /// where one sits, 2 m out, so the 3D window showed as much of the far field as the 2D picture:
    /// near things came out four times deeper than wide, "Link's head is an egg shape, the position
    /// of his eyes between my left and right eye disagree, items close to the camera get warped". Only
    /// a scale in depth can show the far field less magnified from farther than the camera's place;
    /// any mapping that keeps shapes shows it at its true angles. True shapes come first.) What's
    /// nearer than the glass keeps its shape, cut at the front allowance, and the glass comes no
    /// farther than the ground at the window's foot (aurora 0111's sill); a telephoto shot keeps
    /// its depth too (TPVR compresses those, tan / 0.7): the game draws half as wide again in 3D
    /// (GameScreen.viewScale), so someone nearer than the camera's place sees no edge to the world.
    ///
    /// And re-aimed: the game's camera looks down at Link, and the window shows a narrow cone about
    /// its axis (the far field at its true angles), so the distance, in the 2D picture's top third,
    /// fell outside it ("the 3D camera feels more angled toward the ground"). The world is turned,
    /// taking out the camera's downward pitch, at most `reaim.cap`, about the game camera's own
    /// place: turned about the focus, and lowered by the camera's height above it (`raise`, at most
    /// 0.4 of the window's half-height). As the game's camera, levelled: the horizon at the eye,
    /// Link lower in the window, the ground in front of the glass lower still (turned about the
    /// focus, a7b10cc, the eye came down to the focus's height, and the near ground ran out
    /// higher in the window, toward the glass). A turn and a shift keep every shape. It eases toward a new pitch (a quarter of a second: the
    /// camera's own moves, an event's camera handing back), and jumps with a cut (the host's
    /// wwvr_visionos_mirror_frame.cut) or as the mirror starts; none in first person, in an event's
    /// camera (a close-up is framed about Aryll, not the focus far behind her), nor looking up; none
    /// as the world lies flat for 2D, so the flat world is the game's own picture.
    private func place(_ frame: wwvr_visionos_mirror_frame) {
        let plane = max(frame.plane, 1e-3)
        let tan = max(frame.tan_half_x, 1e-3)
        self.plane = plane
        self.depthScale = 1
        let scale = 1 / (2 * plane * tan)
        let wanted = Self.reaim.fraction * min(max(framePitch, 0), Self.reaim.cap) + Self.reaim.extra
        let now = CACurrentMediaTime()
        if !hasScene || cutSincePlaced {
            if cutSincePlaced { counts.cuts += 1 }
            aim = wanted
        } else {
            aim += (wanted - aim) * (1 - exp(-Float(min(max(now - aimTime, 0), 0.1)) / 0.25))
        }
        cutSincePlaced = false
        aimTime = now
        placedTangents = [tan, max(frame.tan_half_y, 1e-3)]
        lastFocus = frame.focus
        turnBound = max(aim, wanted, 0)
        let turned = aim * (1 - flatten)
        let turn = simd_quatf(angle: -turned, axis: [1, 0, 0])
        let focus = SIMD3<Float>(0, 0, -max(frame.focus, plane))
        root.orientation = turn
        root.scale = SIMD3(repeating: scale)
        // At most 0.4 of the window's half-height (lower, Link's head leaves the window), and no
        // lower than keeps the drawn view's top at the window's top edge at the glass: the game
        // draws viewScale times its picture's tangent, which a turn past about 11° no longer
        // covers from the camera's own place (the camera's image, `above`, makes up the rest).
        let tanY = max(frame.tan_half_y, 1e-3)
        let halfHeight = tanY / (2 * tan)
        let camera = 1 / (2 * tan)
        let above = scale * max(frame.focus, plane) * sin(turned)
        let drawnTop = Swift.max(0, tanY - Foundation.tan(atan(viewScale * tanY) - turned))
        let lowered = Swift.max(0, Swift.min(Self.raise * above, 0.4 * halfHeight, above - camera * drawnTop))
        root.position = scale * (focus - turn.act(focus)) + [0, -lowered, scale * plane]
        // Wide enough behind everything for anyone a quarter of a width from the glass or farther.
        let far = max(-frame.bounds_min.2, plane) * 1.05
        let wide = 2 * far * max(8 * tan, 2)
        backdrop.position = [0, 0, -far]
        backdrop.scale = [wide, wide, 1]
    }

    // MARK: - The mesh

    /// position float3, uv0 float2, the multiplier half4 (vertex colour), the addend half2 x 2
    /// (uv1, uv2): wwvr_visionos_mirror_vertex.
    private static func descriptor(vertices: Int, indices: Int) -> LowLevelMesh.Descriptor {
        LowLevelMesh.Descriptor(
            vertexCapacity: vertices,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 12),
                               .init(semantic: .color, format: .half4, layoutIndex: 0, offset: 20),
                               .init(semantic: .uv1, format: .half2, layoutIndex: 0, offset: 28),
                               .init(semantic: .uv2, format: .half2, layoutIndex: 0, offset: 32)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 36)],
            indexCapacity: indices, indexType: .uint32)
    }

    /// The frame into the level mesh not on screen (made, or made bigger or smaller, when it doesn't
    /// fit or is far too big): its vertices, and the solid parts' indices each in its region. The
    /// index of the mesh filled and its parts; nil when there's none to fill.
    private func fill(vertices: UnsafePointer<wwvr_visionos_mirror_vertex>, vertexCount: Int,
                      indices: UnsafePointer<UInt32>, parts: UnsafePointer<wwvr_visionos_mirror_part>,
                      keys: [MaterialKey], solid: [(index: Int, materialIndex: Int)],
                      bounds: BoundingBox, plane framePlane: Float) -> (Int, [LowLevelMesh.Part])? {
        let index = Self.oneLevelMesh ? shownMesh : 1 - shownMesh
        // Each part's region: the one it had, or a new one after the rest when it has none or has
        // outgrown it (half as much again as it needs, so a part that grows a little stays put).
        var layout = levelMeshes[index]?.regions ?? [:]
        var end = levelMeshes[index]?.regionsEnd ?? 0
        var placed: [(region: Region, first: Int, count: Int)] = []
        var occurrences: [MaterialKey: Int] = [:]
        func place(_ fresh: Bool) {
            if fresh {
                layout = [:]
                end = 0
            }
            placed = []
            occurrences = [:]
            for (partIndex, _) in solid {
                let key = keys[partIndex]
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                let regionKey = RegionKey(key: key, occurrence: occurrence)
                let count = Int(parts[partIndex].index_count)
                if layout[regionKey].map({ $0.capacity < count }) ?? true {
                    layout[regionKey] = Region(offset: end, capacity: (count + count / 2).roundedUp(to: 96))
                    end += layout[regionKey]!.capacity
                }
                placed.append((layout[regionKey]!, Int(parts[partIndex].first_index), count))
            }
        }
        place(false)
        // Laid out afresh (only this frame's parts) when the regions no longer fit: parts gone
        // leave theirs behind until then.
        let current = levelMeshes[index]?.mesh
        if end > (current?.indexCapacity ?? 0) {
            place(true)
            // Into a new mesh: this one's last indices are in the old layout, and a frame-old read
            // of them would put other parts' triangles in every part again.
            if current != nil { levelMeshes[index] = nil }
        }
        // A quarter more indices than this frame lays out, so new parts and outgrown regions find
        // room past the end for a while before the layout starts again. Grown in steps, not doubled:
        // each write goes into a fresh buffer of the mesh's capacity, and past some size between 3.2
        // and 4.3 MB those cost RealityKit 12 to 15 ms instead of 0.3 (TPVR, 36 bytes a vertex).
        let fresh = (vertices: max(65536, vertexCount.roundedUp(to: 8192)),
                     indices: max(196608, (end * 5 / 4).roundedUp(to: 16384)))
        notePeak(vertices: vertexCount, indices: end)
        // Sized down once it's a quarter bigger than lately needed and past the slow size.
        let recent = (vertices: max(peak.vertices, peak.previousVertices), indices: max(peak.indices, peak.previousIndices))
        let oversized = (levelMeshes[index]?.mesh).map {
            $0.vertexCapacity * 36 > 3_200_000 && $0.vertexCapacity > (recent.vertices * 5 / 4).roundedUp(to: 8192)
        } ?? false
        if oversized {
            let smaller = (vertices: max(65536, recent.vertices.roundedUp(to: 8192)),
                           indices: max(196608, (recent.indices * 5 / 4).roundedUp(to: 16384)))
            if let made = try? LowLevelMesh(descriptor: Self.descriptor(vertices: max(smaller.vertices, fresh.vertices),
                                                                        indices: max(smaller.indices, fresh.indices))) {
                levelMeshes[index] = LevelMesh(mesh: made)
                counts.meshesMade += 1
            }
        }
        if levelMeshes[index].map({ $0.mesh.vertexCapacity < vertexCount || $0.mesh.indexCapacity < end }) ?? true {
            do {
                // (Never smaller than the last in either: frames alternating between more vertices
                // and more indices would make a mesh each time.)
                let grown = levelMeshes[index]?.mesh
                let made = try LowLevelMesh(descriptor: Self.descriptor(
                    vertices: max(fresh.vertices, grown?.vertexCapacity ?? 0),
                    indices: max(fresh.indices, grown?.indexCapacity ?? 0)))
                levelMeshes[index] = LevelMesh(mesh: made)
                counts.meshesMade += 1
            } catch {
                print("[WWVR] mirror: a mesh of \(vertexCount) vertices failed: \(error)")
                return nil
            }
        }
        guard let mesh = levelMeshes[index]?.mesh else { return nil }
        levelMeshes[index]?.regions = layout
        levelMeshes[index]?.regionsEnd = end
        counts.fills += 1
        // Into fresh buffers RealityKit swaps in once written (SHAR: written in place, the
        // headset's renderer drew between the vertices and the indices).
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: vertices, count: vertexCount * 36))
            if flatten > 0 {
                for index in 0..<vertexCount { Self.flatten(raw.baseAddress! + index * 36, plane: framePlane, by: flatten) }
            }
            // Test runs: WWVR_TEST_MIRROR_ADD_RED=1 makes every vertex mul 0, add opaque red: the
            // window should be solid red where the mirror draws (it checks uv1/uv2 reach the materials).
            if Self.addRed {
                for index in 0..<vertexCount { Self.paintRed(raw.baseAddress! + index * 36) }
            }
        }
        // Empty triangles everywhere but the parts' own indices: the rest of each region, and the
        // regions of parts not in this frame.
        mesh.replaceUnsafeMutableIndices { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (region, first, count) in placed {
                (raw.baseAddress! + region.offset * 4).copyMemory(from: indices + first, byteCount: count * 4)
            }
        }
        let levelParts = zip(solid, placed).map { part, placement in
            LowLevelMesh.Part(indexOffset: placement.region.offset * 4, indexCount: placement.count, topology: .triangle,
                              materialIndex: part.materialIndex, bounds: bounds)
        }
        return (index, levelParts)
    }

    /// Notes this frame's needs in the 10-s peak (`peak`).
    private func notePeak(vertices: Int, indices: Int) {
        let now = CACurrentMediaTime()
        if now - peak.since > 10 {
            peak = (vertices, indices, peak.vertices, peak.indices, now)
        } else {
            peak.vertices = max(peak.vertices, vertices)
            peak.indices = max(peak.indices, indices)
        }
    }

    /// The level mesh just filled, its parts set, on screen: false when it can't be, and the level
    /// is hidden for the frame rather than showing an older one. A new mesh's resource is made now
    /// that it has its parts; with none yet (every part waiting for its texture), it waits. (Made
    /// from a new mesh with none and given its parts in the same update, the level stayed invisible
    /// for the whole run, now and then: one Simulator launch in five or so.)
    private func show(_ index: Int, hasParts: Bool) -> Bool {
        guard var level = levelMeshes[index] else { return false }
        if level.resource == nil {
            guard hasParts else { return false }
            do { level.resource = try MeshResource(from: level.mesh) } catch {
                Self.report("the level's mesh resource failed: \(error)")
                return false
            }
            levelMeshes[index] = level
        }
        guard let resource = level.resource else { return false }
        if resource !== shownResource {
            if entity.model == nil {
                entity.model = ModelComponent(mesh: resource, materials: currentMaterials())
            } else {
                entity.model?.mesh = resource
            }
            shownResource = resource
        }
        shownMesh = index
        return true
    }

    /// The vertex at `vertex` moved `amount` of the way along its line of sight onto the glass, at
    /// view depth `plane` (WindowDepth's flattening): from the game camera's place the picture is the
    /// same at any amount. Flat, it keeps its order in depth in a band just behind the glass
    /// (`flatBand` of the glass's distance, the sky at the back of it): laid on one plane, everything
    /// at one depth, the first part drawn hid the rest (the sky took the whole picture).
    private static func flatten(_ vertex: UnsafeMutableRawPointer, plane: Float, by amount: Float) {
        let p = vertex.assumingMemoryBound(to: Float.self)
        let depth = -p[2]
        guard depth > 1e-3 else { return }
        // -1 at the camera, 0 at the glass, 1 at infinity: the order kept, within the band.
        let order = depth >= plane ? 1 - plane / depth : depth / plane - 1
        let flat = plane * (1 + flatBand * order)
        let scale = 1 + amount * (flat / depth - 1)
        p[0] *= scale
        p[1] *= scale
        p[2] *= scale
    }
    private static let flatBand: Float = 0.05

    /// Bounds taking in the glass's part of the view too (what's flattened lies there, in its band).
    private static func withGlass(_ low: SIMD3<Float>, _ high: SIMD3<Float>,
                                  _ frame: wwvr_visionos_mirror_frame) -> (SIMD3<Float>, SIMD3<Float>) {
        let plane = max(frame.plane, 1e-3)
        let back = plane * (1 + flatBand), front = plane * (1 - flatBand)
        let half = SIMD2(back * frame.tan_half_x, back * frame.tan_half_y) * 2
        return (simd_min(low, [-half.x, -half.y, -back]), simd_max(high, [half.x, half.y, -front]))
    }

    /// No frame shows until one of a game frame after `gameFrame` (the window's, now): the mirror
    /// runs again after stopping, and what it had, or had finished just before, is old.
    func resume(after gameFrame: UInt32) {
        awaitingFresh = true
        resumedAfter = gameFrame
        whole = false
    }

    /// Game frame numbers are 24 bits (aurora's not_after): whether `a` is `b` or before it.
    private static func notAfter(_ a: UInt32, _ b: UInt32) -> Bool { (b &- a) & 0xFFFFFF < 0x800000 }

    /// WWVR_TEST_MIRROR_ADD_RED: the vertex at `vertex` gets mul 0, add opaque red.
    private static func paintRed(_ vertex: UnsafeMutableRawPointer) {
        let red: [UInt16] = [0, 0, 0, 0, 0x3C00, 0, 0, 0x3C00]  // half 1.0 = 0x3C00
        red.withUnsafeBytes { (vertex + 20).copyMemory(from: $0.baseAddress!, byteCount: 16) }
    }

    /// Each blended part into the slot that had its material last frame, if one did: by position, a
    /// dust puff appearing mid-list moved every later part to another slot, its geometry and
    /// material changing at once (which RealityKit may not show in the same frame).
    private func fillSlots(_ blendedParts: [(index: Int, material: ShaderGraphMaterial, order: Int32)],
                           parts: UnsafePointer<wwvr_visionos_mirror_part>, keys: [MaterialKey],
                           vertices: UnsafePointer<wwvr_visionos_mirror_vertex>, vertexCount: Int,
                           indices: UnsafePointer<UInt32>, frame: wwvr_visionos_mirror_frame) {
        var taken = [Bool](repeating: false, count: blendSlots.count)
        var byMaterial: [MaterialKey: [Int]] = [:]
        for (s, slot) in blendSlots.enumerated().reversed() {
            if let key = slot.material { byMaterial[key, default: []].append(s) }
        }
        var slotFor = [Int](repeating: -1, count: blendedParts.count)
        for (k, part) in blendedParts.enumerated() {
            if let s = byMaterial[keys[part.index]]?.popLast() {
                slotFor[k] = s
                taken[s] = true
            }
        }
        var free = 0
        var blended = 0
        for (k, part) in blendedParts.enumerated() {
            var s = slotFor[k]
            if s < 0 {
                while free < taken.count && taken[free] { free += 1 }
                if free == taken.count {
                    let slot = BlendSlot()
                    root.addChild(slot.entity)
                    blendSlots.append(slot)
                    taken.append(false)
                }
                s = free
                taken[s] = true
            }
            if fillBlend(blendSlots[s], order: part.order, part: parts[part.index], key: keys[part.index], material: part.material,
                         vertices: vertices, vertexCount: vertexCount, indices: indices, frame: frame) {
                blended += 1
            } else {
                blendSlots[s].entity.isEnabled = false
            }
        }
        for (s, slot) in blendSlots.enumerated() where !taken[s] { slot.entity.isEnabled = false }
        last.blended = blended
    }

    /// A blended or background part into `slot`, drawn as `order` in the sort group: only the vertices it uses
    /// (most of the frame's are solid), its indices renumbered, one part. False: the slot shows nothing.
    private func fillBlend(_ slot: BlendSlot, order: Int32, part: wwvr_visionos_mirror_part, key: MaterialKey,
                           material: ShaderGraphMaterial, vertices: UnsafePointer<wwvr_visionos_mirror_vertex>,
                           vertexCount: Int, indices: UnsafePointer<UInt32>, frame: wwvr_visionos_mirror_frame) -> Bool {
        let first = Int(part.first_index), count = Int(part.index_count)
        guard count > 0 else { return false }
        if remap.count < vertexCount { remap = [Int32](repeating: -1, count: vertexCount) }
        var used: [UInt32] = []
        used.reserveCapacity(count)
        var local = [UInt32](repeating: 0, count: count)
        for i in 0..<count {
            let v = Int(indices[first + i])
            guard v < vertexCount else { continue }
            if remap[v] < 0 {
                remap[v] = Int32(used.count)
                used.append(UInt32(v))
            }
            local[i] = UInt32(remap[v])
        }
        for v in used { remap[Int(v)] = -1 }
        guard !used.isEmpty else { return false }
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for v in used {
            let p = vertices[Int(v)].position
            let point = SIMD3(p.0, p.1, p.2)
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        if flatten > 0 { (low, high) = Self.withGlass(low, high, frame) }
        let pad = (high - low) * 0.05 + 1
        let bounds = BoundingBox(min: low - pad, max: high + pad)
        // A bigger mesh replaces the slot's only once its resource is made: kept on failure, the
        // slot would go on drawing the old resource while the next frames wrote into the new mesh.
        var fresh = false
        var target = slot.mesh
        // Made again when it doesn't fit, or when it's big and four times what the part needs (its
        // room otherwise only grew, as the level's did).
        if target.map({ $0.vertexCapacity < used.count || $0.indexCapacity < count
                        || ($0.vertexCapacity > 16384 && $0.vertexCapacity > used.count.nextPowerOfTwo * 4) }) ?? true {
            guard let made = try? LowLevelMesh(descriptor: Self.descriptor(
                vertices: max(256, used.count.nextPowerOfTwo), indices: max(768, count.nextPowerOfTwo))) else {
                return false
            }
            target = made
            fresh = true
        }
        guard let mesh = target else { return false }
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            for (j, v) in used.enumerated() {
                let at = raw.baseAddress! + j * 36
                at.copyMemory(from: vertices + Int(v), byteCount: 36)
                if flatten > 0 { Self.flatten(at, plane: max(frame.plane, 1e-3), by: flatten) }
                if Self.addRed { Self.paintRed(at) }
            }
        }
        // Empty triangles after the part's own (its count changes; see LevelMesh).
        mesh.replaceUnsafeMutableIndices { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            local.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexOffset: 0, indexCount: count, topology: .triangle,
                                                 materialIndex: 0, bounds: bounds)])
        // The resource only once the mesh has its part (RealityKit rules: made from a mesh without
        // one, it now and then never drew). The material only when the slot's key changes: set again
        // each frame, it may cost the renderer a frame.
        if fresh {
            guard let resource = try? MeshResource(from: mesh) else { return false }
            slot.mesh = mesh
            slot.entity.model = ModelComponent(mesh: resource, materials: [material])
            slot.material = key
        } else if slot.material != key {
            slot.entity.model?.materials = [material]
            slot.material = key
        }
        if slot.order != order, let sortGroup {
            slot.entity.components.set(ModelSortGroupComponent(group: sortGroup, order: order))
            slot.order = order
        }
        slot.entity.isEnabled = true
        return true
    }

    // MARK: - Materials

    private func updateMaterials(_ keys: [MaterialKey]) {
        var changed = false
        // Counting new materials, not parts: blended parts in the game's order repeat theirs, and
        // counting parts cleared and set the list every frame of a busy scene (SHAR's review), which
        // may cost the renderer a frame of the whole level.
        let fresh = Set(keys).filter { materialIndex[$0] == nil }.count
        if materialList.count + fresh > 1024 {
            materialList = []
            materialIndex = [:]
            materialReady = []
            changed = true
        }
        if texturesArrived {
            texturesArrived = false
            changed = changed || materialList.indices.contains { !materialReady[$0] && material(for: materialList[$0]) != nil }
        }
        for key in keys where materialIndex[key] == nil {
            materialIndex[key] = materialList.count
            materialList.append(key)
            changed = true
        }
        guard changed else { return }
        counts.materialSets += 1
        materialReady = materialList.map { material(for: $0) != nil }
        entity.model?.materials = currentMaterials()
    }

    /// The material list the parts index (a stand-in where a texture is still on its way).
    private func currentMaterials() -> [any Material] {
        materialList.map { material(for: $0) ?? templates["OpaqueRR"]! }
    }

    private func material(for key: MaterialKey) -> ShaderGraphMaterial? {
        if let made = materials[key] { return made }
        let texture = key.texture == 0 || failedTextures.contains(key.texture) ? white : textures[key.texture]
        guard let texture else { return nil }
        let kind = key.kind == WWVR_VISIONOS_MIRROR_PART_CUTOUT ? "Cutout" : key.kind == WWVR_VISIONOS_MIRROR_PART_BLEND ? "Blend" : "Opaque"
        guard var made = templates[kind + key.wrap] ?? templates[kind + "RR"] else { return nil }
        try? made.setParameter(name: "Frame", value: .textureResource(texture))
        switch key.kind {
        case WWVR_VISIONOS_MIRROR_PART_CUTOUT:
            try? made.setParameter(name: "Cutoff", value: .float(Float(max(key.cutoff, 1)) / 255))
        case WWVR_VISIONOS_MIRROR_PART_BLEND:
            for (index, name) in ["ColourBase", "ColourAlpha", "OpacityBase", "OpacityAlpha", "OpacityLuma"].enumerated() {
                try? made.setParameter(name: name, value: .float(Float(key.weights[index]) / 16))
            }
            // Blended surfaces hide what's behind them only where the game's do.
            made.writesDepth = key.flags & WWVR_VISIONOS_MIRROR_DEPTH_WRITE != 0
        default:
            break
        }
        // A blend the game draws without a depth test draws over everything.
        made.readsDepth = key.flags & WWVR_VISIONOS_MIRROR_DEPTH_TEST != 0 || key.kind != WWVR_VISIONOS_MIRROR_PART_BLEND
        // The background (the sky's dome, clouds and horizon, drawn by the game before anything wrote
        // depth) is drawn first, in the game's order, and neither tests nor writes depth: the level
        // drawn after covers it. Writing depth, the dome hid the clouds behind it in straight-edged
        // pieces; drawn after the level, the horizon's haze layers, pushed only so far from the
        // camera, lay over the sea and turned it pale.
        if key.flags & WWVR_VISIONOS_MIRROR_BACKGROUND != 0 && !Self.oneMesh {
            made.readsDepth = false
            made.writesDepth = false
        }
        made.faceCulling = key.flags & WWVR_VISIONOS_MIRROR_CULL_BACK != 0 ? .back
            : key.flags & WWVR_VISIONOS_MIRROR_CULL_FRONT != 0 ? .front : .none
        // Test runs: WWVR_TEST_MIRROR_CULL=none draws both sides, =flip culls the other side.
        switch Self.cullTest {
        case "none": made.faceCulling = .none
        case "flip": made.faceCulling = made.faceCulling == .back ? .front : made.faceCulling == .front ? .back : .none
        default: break
        }
        if materials.count > 4096 { materials.removeAll(keepingCapacity: true) }
        materials[key] = made
        return made
    }

    // MARK: - Textures

    private func takeTextures(_ frame: wwvr_visionos_mirror_frame, start: CFTimeInterval) {
        if let list = frame.textures {
            for index in 0..<Int(frame.texture_count) {
                let texture = list[index]
                let count = Int(texture.width) * Int(texture.height) * 4
                guard let rgba = texture.rgba, count > 0 else { continue }
                // Back after being let go: the same texture, still here (below).
                if parkedSet.remove(texture.id) != nil {
                    parked.removeAll { $0 == texture.id }
                }
                // A mipmapped id is its pixels (scene_mirror.h): the one made stands.
                if texture.mipmapped, textures[texture.id] != nil { continue }
                // New pixels for one already made (a shadow, each frame): replaced in place.
                if let existing = lowLevelTextures[texture.id], Self.updatesInPlace(existing, width: Int(texture.width),
                                                                                    height: Int(texture.height),
                                                                                    cutout: texture.cutout) {
                    Self.upload(queue: queue, pixels: rgba, width: Int(texture.width), height: Int(texture.height), into: existing)
                    continue
                }
                let pending = PendingTexture(id: texture.id, pixels: Data(bytes: rgba, count: count),
                                             width: Int(texture.width), height: Int(texture.height),
                                             mipmapped: texture.mipmapped, cutout: texture.cutout)
                // A newer read-back of one still waiting replaces it.
                if let waiting = pendingTextures.firstIndex(where: { $0.id == texture.id }) {
                    pendingTextures[waiting] = pending
                } else {
                    pendingTextures.append(pending)
                }
            }
        }
        // After the new ones: a texture can arrive and be gone in the same frame. An area's
        // textures go together, a few hundred at once: one pass over each collection.
        // Those made are parked, not dropped; one that couldn't be made (drawn white) loses its
        // materials, so that when it comes back and is made, its parts wait for it and the list is
        // set once.
        if let removed = frame.removed, frame.removed_count > 0 {
            let gone = Set((0..<Int(frame.removed_count)).map { removed[$0] })
            var failedGone: Set<UInt64> = []
            for id in gone where !parkedSet.contains(id) {
                if textures[id] != nil {
                    parked.append(id)
                    parkedSet.insert(id)
                } else if failedTextures.remove(id) != nil {
                    failedGone.insert(id)
                }
            }
            if !failedGone.isEmpty { forgetMaterials(using: failedGone) }
            pendingTextures.removeAll { gone.contains($0.id) }
            dropParked(beyond: Self.parkedBudget)
        }
        // Wanted ones first, then a few milliseconds' worth an update, at least one.
        if !wantedTextures.isEmpty {
            let wanted = pendingTextures.filter { wantedTextures.contains($0.id) }
            pendingTextures = wanted + pendingTextures.filter { !wantedTextures.contains($0.id) }
            wantedTextures.removeAll()
        }
        var made = 0
        while !pendingTextures.isEmpty && (made == 0 || CACurrentMediaTime() - start < 0.004) {
            let pending = pendingTextures.removeFirst()
            if Self.dumpFrame >= 0 {
                dumpTextures[pending.id] = pending
            }
            // Read back again before its first was made: into the texture already there.
            if let existing = lowLevelTextures[pending.id],
               Self.updatesInPlace(existing, width: pending.width, height: pending.height, cutout: pending.cutout) {
                pending.pixels.withUnsafeBytes {
                    Self.upload(queue: queue, pixels: $0.bindMemory(to: UInt8.self).baseAddress!, width: pending.width,
                                height: pending.height, into: existing)
                }
                made += 1
                continue
            }
            if let (lowLevel, resource) = makeTexture(pending) {
                // A new resource for an id already drawn (a resized render target): materials made
                // with the old one would keep drawing it.
                if textures[pending.id] != nil || failedTextures.contains(pending.id) {
                    forgetMaterials(using: [pending.id])
                }
                failedTextures.remove(pending.id)
                textures[pending.id] = resource
                lowLevelTextures[pending.id] = lowLevel
                counts.texturesMade += 1
            } else {
                failedTextures.insert(pending.id)
                counts.texturesFailed += 1
            }
            texturesArrived = true
            made += 1
        }
    }

    /// Drops the materials made with these textures and marks their list entries not ready, so the
    /// parts wait for the texture (again) and the list is set anew once it's there. A blended part's
    /// slot forgets its material too: it sets one only when its key changes, so it stayed white.
    private func forgetMaterials(using ids: Set<UInt64>) {
        materials = materials.filter { !ids.contains($0.key.texture) }
        for (index, key) in materialList.enumerated() where ids.contains(key.texture) {
            materialReady[index] = false
        }
        for slot in blendSlots where slot.material.map({ ids.contains($0.texture) }) == true {
            slot.material = nil
        }
    }

    /// Lets the longest-gone parked textures go for good, with their materials, until the rest fit.
    private func dropParked(beyond budget: Int) {
        var bytes = parked.reduce(0) { $0 + Self.bytes(of: lowLevelTextures[$1]) }
        guard bytes > budget else { return }
        var dropped: Set<UInt64> = []
        while bytes > budget, !parked.isEmpty {
            let id = parked.removeFirst()
            parkedSet.remove(id)
            bytes -= Self.bytes(of: lowLevelTextures[id])
            textures[id] = nil
            lowLevelTextures[id] = nil
            dropped.insert(id)
        }
        forgetMaterials(using: dropped)
    }

    private static func bytes(of texture: LowLevelTexture?) -> Int {
        guard let descriptor = texture?.descriptor else { return 0 }
        let level = descriptor.width * descriptor.height * 4
        return descriptor.mipmapLevelCount > 1 ? level * 4 / 3 : level
    }

    /// Whether new pixels can go into the texture already made: the same size, and its mipmaps (if
    /// any) ones the GPU makes (a cut-out's are made on the CPU, so it gets a new texture).
    private static func updatesInPlace(_ texture: LowLevelTexture, width: Int, height: Int, cutout: Bool) -> Bool {
        texture.descriptor.width == width && texture.descriptor.height == height
            && (texture.descriptor.mipmapLevelCount == 1 || !cutout)
    }

    private func makeTexture(_ texture: PendingTexture) -> (LowLevelTexture, TextureResource)? {
        let levels = texture.mipmapped && texture.cutout ? Self.coverageMipmaps(texture) : nil
        return (levels ?? texture.pixels).withUnsafeBytes {
            Self.makeTexture(queue: queue, pixels: $0.baseAddress!, width: texture.width, height: texture.height,
                             mipmapped: texture.mipmapped, levelsIncluded: levels != nil)
        }
    }

    private static func makeTexture(queue: MTLCommandQueue, pixels: [UInt8], width: Int, height: Int) -> TextureResource? {
        pixels.withUnsafeBytes { makeTexture(queue: queue, pixels: $0.baseAddress!, width: width, height: height)?.1 }
    }

    /// New level-zero pixels into a texture already made.
    private static func upload(queue: MTLCommandQueue, pixels: UnsafePointer<UInt8>, width: Int, height: Int,
                               into texture: LowLevelTexture) {
        guard let staging = queue.device.makeBuffer(bytes: pixels, length: width * height * 4) else {
            report("a \(width)x\(height) texture update: no staging buffer")
            return
        }
        blit(staging, into: texture, sizes: [(width, height)], generate: texture.descriptor.mipmapLevelCount > 1,
             queue: queue, label: "a \(width)x\(height) texture update")
    }

    /// The staging buffer's levels into the texture (the GPU making the rest with `generate`). One the
    /// GPU reports failing is tried again, once, into the same texture, so what draws it needn't
    /// change. (The SHAR port's headset-only "black void", ground and sky gone, was failed uploads
    /// the Simulator never showed: they'd have gone unnoticed here.)
    @discardableResult
    private static func blit(_ staging: MTLBuffer, into texture: LowLevelTexture, sizes: [(Int, Int)], generate: Bool,
                             queue: MTLCommandQueue, label: String, retries: Int = 1) -> Bool {
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            report("\(label): no command buffer")
            return false
        }
        let destination = texture.replace(using: commands)
        var offset = 0
        for (level, (levelWidth, levelHeight)) in sizes.enumerated() {
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: levelWidth * 4,
                      sourceBytesPerImage: levelWidth * levelHeight * 4,
                      sourceSize: MTLSize(width: levelWidth, height: levelHeight, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: level, destinationOrigin: MTLOrigin())
            offset += levelWidth * levelHeight * 4
        }
        if generate { blit.generateMipmaps(for: destination) }
        blit.endEncoding()
        uploadsInFlight.add(1, ordering: .relaxed)
        commands.addCompletedHandler { done in
            uploadsInFlight.subtract(1, ordering: .relaxed)
            guard let error = done.error else { return }
            let message = "\(label): upload failed\(retries > 0 ? ", trying again" : ""): \(error)"
            DispatchQueue.main.async {
                report(message)
                if retries > 0 {
                    Self.blit(staging, into: texture, sizes: sizes, generate: generate, queue: queue, label: label,
                              retries: retries - 1)
                }
            }
        }
        commands.commit()
        return true
    }

    // The first few failures, word for word.
    private static var reports = 0
    private static func report(_ message: String) {
        reports += 1
        if reports <= 20 { print("[WWVR] mirror: \(message)") }
    }

    /// RGBA8 (sRGB) into a texture, its mipmaps made by the GPU or, with `levelsIncluded`, given
    /// one after another in `pixels`.
    private static func makeTexture(queue: MTLCommandQueue, pixels: UnsafeRawPointer, width: Int, height: Int,
                                    mipmapped: Bool = false, levelsIncluded: Bool = false) -> (LowLevelTexture, TextureResource)? {
        let levels = mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height,
                                                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .renderTarget])
        let label = "a \(width)x\(height) texture"
        let texture: LowLevelTexture
        do { texture = try LowLevelTexture(descriptor: descriptor) } catch {
            report("\(label): LowLevelTexture failed: \(error)")
            return nil
        }
        let sizes = (0..<(levelsIncluded ? levels : 1)).map { (max(1, width >> $0), max(1, height >> $0)) }
        guard let staging = queue.device.makeBuffer(bytes: pixels, length: sizes.reduce(0) { $0 + $1.0 * $1.1 * 4 }) else {
            report("\(label): no staging buffer")
            return nil
        }
        // (It reports its own failures.)
        guard Self.blit(staging, into: texture, sizes: sizes, generate: levels > 1 && !levelsIncluded, queue: queue,
                        label: label) else { return nil }
        do { return (texture, try TextureResource(from: texture)) } catch {
            report("\(label): TextureResource failed: \(error)")
            return nil
        }
    }

    /// A cut-out texture's mipmaps (SHAR's): each texel the alpha-weighted mean of the four below
    /// it, its alpha scaled so as many texels pass a half alpha test as at full size. A box filter
    /// alone thins foliage with distance, and its edges shimmer.
    private static func coverageMipmaps(_ texture: PendingTexture) -> Data? {
        var width = texture.width, height = texture.height
        guard width > 1 || height > 1 else { return nil }
        var level = [UInt8](texture.pixels)
        let covered = { (pixels: [UInt8], scale: Float) -> Int in
            stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (Float(pixels[$1]) * scale >= 127.5 ? 1 : 0) }
        }
        let coverage = Float(covered(level, 1)) / Float(width * height)
        var chain = Data(level)
        while width > 1 || height > 1 {
            let nextWidth = max(1, width / 2), nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            for y in 0..<nextHeight {
                for x in 0..<nextWidth {
                    var colour = SIMD3<Float>.zero, plain = SIMD3<Float>.zero, alpha: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let at = (min(y * 2 + dy, height - 1) * width + min(x * 2 + dx, width - 1)) * 4
                        let texel = SIMD3<Float>(Float(level[at]), Float(level[at + 1]), Float(level[at + 2]))
                        let a = Float(level[at + 3])
                        colour += texel * a
                        plain += texel
                        alpha += a
                    }
                    let rgb = alpha > 0 ? colour / alpha : plain / 4
                    let at = (y * nextWidth + x) * 4
                    next[at] = UInt8(rgb.x.rounded())
                    next[at + 1] = UInt8(rgb.y.rounded())
                    next[at + 2] = UInt8(rgb.z.rounded())
                    next[at + 3] = UInt8((alpha / 4).rounded())
                }
            }
            var low: Float = 0, high: Float = 8
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if Float(covered(next, middle)) / Float(nextWidth * nextHeight) < coverage { low = middle } else { high = middle }
            }
            for at in stride(from: 3, to: next.count, by: 4) { next[at] = UInt8(min(255, (Float(next[at]) * high).rounded())) }
            chain.append(contentsOf: next)
            (level, width, height) = (next, nextWidth, nextHeight)
        }
        return chain
    }

    // MARK: - Test runs

    // WWVR_TEST_MIRROR_DUMP=<frame> writes that mirror frame raw into Documents/mirror-dump:
    // vertices.bin (36-byte vertices), indices.bin (u32), parts.txt, camera.txt (the tangents, the
    // focus, the bounds, the glass's distance and the pitch), and the textures made so far
    // (tex-<id>-<w>x<h>.rgba).
    private static let dumpFrame = TestHooks.value("WWVR_TEST_MIRROR_DUMP").flatMap(Int.init) ?? -1
    private var dumpTextures: [UInt64: PendingTexture] = [:]

    private func dump(_ frame: wwvr_visionos_mirror_frame) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirror-dump")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let vertices = frame.vertices {
            try? Data(bytes: vertices, count: Int(frame.vertex_count) * 36).write(to: folder.appendingPathComponent("vertices.bin"))
        }
        if let indices = frame.indices {
            try? Data(bytes: indices, count: Int(frame.index_count) * 4).write(to: folder.appendingPathComponent("indices.bin"))
        }
        var parts = ""
        for index in 0..<Int(frame.part_count) {
            let p = frame.parts![index]
            parts += "\(p.first_index) \(p.index_count) \(p.texture) \(p.kind) \(p.flags) \(p.cutoff) "
                + "\(p.colour_base) \(p.colour_alpha) \(p.opacity_base) \(p.opacity_alpha) \(p.opacity_luma) "
                + "\(p.wrap_s) \(p.wrap_t)\n"
        }
        try? parts.write(to: folder.appendingPathComponent("parts.txt"), atomically: true, encoding: .utf8)
        // (Then the glass's distance and the camera's pitch, as the frame was placed with them.)
        let camera = "\(frame.tan_half_x) \(frame.tan_half_y) \(frame.focus) \(frame.bounds_min) \(frame.bounds_max) "
            + "\(frame.plane) \(frame.pitch)\n"
        try? camera.write(to: folder.appendingPathComponent("camera.txt"), atomically: true, encoding: .utf8)
        for (id, texture) in dumpTextures {
            try? texture.pixels.write(to: folder.appendingPathComponent("tex-\(id)-\(texture.width)x\(texture.height).rgba"))
        }
        print("[WWVR] mirror frame dumped: \(frame.vertex_count) vertices, \(frame.part_count) parts, \(dumpTextures.count) textures")
    }

    // MARK: - Report

    /// What the mirror holds, for the window's memory log (WindowMemoryGuard).
    var diagnostics: String {
        let textureBytes = lowLevelTextures.values.reduce(0) { $0 + Self.bytes(of: $1) }
        let waitingBytes = pendingTextures.reduce(0) { $0 + $1.pixels.count }
        return "\(lastReport); last frame \(last.vertices) vertices, \(last.indices) indices, \(last.parts) parts "
            + "(\(last.blended) blended, in \(blendSlots.count) slots); "
            + "\(lowLevelTextures.count) textures (~\(textureBytes >> 20) MB, \(parked.count) parked; "
            + "\(counts.texturesMade) made, \(counts.texturesFailed) failed), \(pendingTextures.count) waiting "
            + "(\(waitingBytes >> 20) MB), \(Self.uploadsInFlight.load(ordering: .relaxed)) uploads in flight, "
            + "\(materials.count) materials (\(materialList.count) listed), mesh room for "
            + "\(levelMeshes[shownMesh]?.mesh.vertexCapacity ?? 0) vertices (\(counts.meshesMade) meshes made, \(counts.fills) fills)"
    }
    private var last = (vertices: 0, indices: 0, parts: 0, blended: 0)
    /// The last 5-s report's rates, for the memory log (the headset doesn't keep stdout).
    private var lastReport = "no report yet"
    /// Texture uploads committed to the GPU and not yet done, for the memory log.
    nonisolated private static let uploadsInFlight = Atomic<Int>(0)

    /// Every 5 s: how often RealityKit updates, how many game frames came, and what they cost here.
    private func report(_ start: CFTimeInterval) {
        timing.updates += 1
        timing.seconds += CACurrentMediaTime() - start
        guard start - timing.since > 5 else { return }
        let updates = Double(timing.updates), frames = Double(max(timing.frames, 1))
        print(String(format: "[WWVR] mirror: %.0f updates/s, %.0f frames/s, %.2f ms an update (fill %.2f, parts %.2f, "
                     + "blended slots %.2f), %.0f vertices and %.0f parts (%.0f drawn) "
                     + "a frame; %d materials, list set %d times; textures %d made, %d failed, %d waiting; "
                     + "re-aim %.1f° (camera cuts so far %d), the glass at %.0f, the focus at %.0f",
                     updates / (start - timing.since), Double(timing.frames) / (start - timing.since),
                     timing.seconds / updates * 1000, stages.fill / updates * 1000, stages.parts / updates * 1000,
                     stages.slots / updates * 1000,
                     Double(timing.vertices) / frames, Double(timing.parts) / frames, Double(timing.drawn) / frames,
                     materials.count, counts.materialSets, counts.texturesMade, counts.texturesFailed, pendingTextures.count,
                     aim * 180 / .pi, counts.cuts, plane, lastFocus))
        lastReport = String(format: "%.0f updates/s, %.0f frames/s, %.2f ms an update (fill %.2f, parts %.2f, slots %.2f)",
                            updates / (start - timing.since), Double(timing.frames) / (start - timing.since),
                            timing.seconds / updates * 1000, stages.fill / updates * 1000, stages.parts / updates * 1000,
                            stages.slots / updates * 1000)
        timing = (0, 0, 0, start, 0, 0, 0, timing.total)
        stages = (0, 0, 0)
        counts.materialSets = 0
    }
}

private extension Int {
    var nextPowerOfTwo: Int { self <= 1 ? 1 : 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount) }
    func roundedUp(to step: Int) -> Int { (self + step - 1) / step * step }
}
