import SwiftUI
import CueATEM

/// One place a camera can be sent: a shot saved in CueVideo, or a preset stored on the camera.
enum DeckItem: Hashable {
    case shot(PTZShot)
    case preset(Int, String)

    var name: String {
        switch self {
        case .shot(let s): s.name
        case .preset(_, let n): n
        }
    }
    /// What the deck remembers as the camera's last-used place.
    var key: String {
        switch self {
        case .shot(let s): "shot:\(s.id)"
        case .preset(let n, _): "preset:\(n)"
        }
    }
    var isPreset: Bool { if case .preset = self { true } else { false } }
}

/// What the shot deck remembers between views and what the keyboard acts on: the page each
/// camera is showing, and the place each camera was last sent to.
final class ShotDeckState: ObservableObject {
    static let shared = ShotDeckState()
    static let perPage = 16, columns = 4, rows = 4

    @Published var page: [UUID: Int] = [:]
    @Published var lastUsed: [UUID: String] = [:]

    /// The keys on the tiles, row by row: Q W E R, T Y U I, then A S D F, G H J K.
    /// (1 to 0 already pick sources.)
    static let letters = ["Q", "W", "E", "R", "T", "Y", "U", "I", "A", "S", "D", "F", "G", "H", "J", "K"]
    static let keyCodes: [UInt16: Int] = [12: 0, 13: 1, 14: 2, 15: 3, 17: 4, 16: 5, 32: 6, 34: 7,
                                          0: 8, 1: 9, 2: 10, 3: 11, 5: 12, 4: 13, 38: 14, 40: 15]

    /// The camera's places in button order: its saved shots, then its own presets.
    func items(_ c: PTZCamera, _ ptz: PTZController) -> [DeckItem] {
        let shots = c.shots.filter { $0.kind == .position }.map { DeckItem.shot($0) }
        let names = ptz.presetNames(c)
        return shots + Self.presets(c, ptz).map { .preset($0, names[$0] ?? "Preset \($0)") }
    }

    /// The camera's own presets in button order (exposure presets live in the exposure panel).
    /// A VISCA camera can't say which presets it holds, so it shows only the ones given a name.
    static func presets(_ c: PTZCamera, _ ptz: PTZController) -> [Int] {
        let place = Dictionary(c.presetOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ptz.presetNames(c).keys.filter { !(ptz.exposurePresets[c.id]?.contains($0) ?? false) }
            .sorted { (place[$0] ?? Int.max, $0) < (place[$1] ?? Int.max, $1) }
    }

    /// Pages the camera needs: its places, plus room for the save tile.
    func pages(_ c: PTZCamera, _ ptz: PTZController) -> Int {
        let n = items(c, ptz).count + (ptz.canSaveShots(c) ? 1 : 0)
        return max(1, (n + Self.perPage - 1) / Self.perPage)
    }

    func page(of c: PTZCamera, _ ptz: PTZController) -> Int { min(page[c.id] ?? 0, pages(c, ptz) - 1) }

    func turn(_ c: PTZCamera, by d: Int, _ ptz: PTZController) {
        page[c.id] = max(0, min(pages(c, ptz) - 1, page(of: c, ptz) + d))
    }

    func go(_ item: DeckItem, camera c: PTZCamera, _ ptz: PTZController) {
        switch item {
        case .shot(let s): ptz.go(to: s, camera: c.id)
        case .preset(let n, _): ptz.recall(n, camera: c.id)
        }
        lastUsed[c.id] = item.key
    }

    /// A tile's key, pressed: sends the camera on Next to that tile on the page it's showing.
    func press(slot: Int, camera c: PTZCamera, _ ptz: PTZController) {
        let items = items(c, ptz), i = page(of: c, ptz) * Self.perPage + slot
        guard i < items.count else { return }
        go(items[i], camera: c, ptz)
    }
}

/// The saved shots: one camera at a time. Tabs across the top, one per camera; the shown camera
/// follows Next, and tapping a tab puts that camera on Next. Its shots fill a 4 by 4 grid of
/// tiles, paged with the arrows (or [ and ]) instead of scrolling. Each tile has a key, Q to K.
/// The last tile saves where the camera is now. Right-click a shot to update, rename or delete it;
/// hold one, then drag it, to put it somewhere else on its page.
/// The Live camera's tab shows its shots, locked: a tap asks before it moves the camera on air.
struct ShotDeck: View {
    @EnvironmentObject var booth: Booth
    @EnvironmentObject var atem: ATEMClient
    @EnvironmentObject var ptz: PTZController
    @EnvironmentObject var store: ConfigStore
    @ObservedObject var deck = ShotDeckState.shared
    @ObservedObject var pictures = ShotPictures.shared

    /// The Live camera, when its tab was tapped. Otherwise the deck shows the camera on Next.
    @State private var viewingLive: UUID?
    @State private var saving = false
    @State private var newName = ""
    @State private var renaming: (camera: UUID, shot: PTZShot)?
    @State private var deleting: (camera: UUID, shot: PTZShot)?
    @State private var deletingPreset: (camera: UUID, n: Int)?
    @State private var liveMove: (camera: UUID, run: () -> Void)?
    @State private var problem: String?
    @State private var drag: ShotDrag?

    static let gap: CGFloat = 6
    static let noReading = "The camera didn't report its settings, so the shot wasn't saved. Check that it's answering and try again."

    var cams: [PTZCamera] { ptz.cameras.filter { !$0.host.isEmpty } }
    func onLive(_ c: PTZCamera) -> Bool { c.atemInput.map { (atem.state.tally[$0] ?? 0) & 1 != 0 } ?? false }
    func onNext(_ c: PTZCamera) -> Bool { c.atemInput != nil && c.atemInput == atem.state.preview[booth.me] }

    var shown: PTZCamera? {
        if let id = viewingLive, let c = cams.first(where: { $0.id == id }), onLive(c) { return c }
        return cams.first(where: onNext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            tabs
            if cams.isEmpty {
                note("No cameras set up yet. Add them in Setup (⌘,).")
            } else if let c = shown {
                if onLive(c) { liveBanner(c) }
                grid(c)
                pager(c)
            } else {
                note("Put a camera on Next to see its shots. Tap a camera above.")
            }
        }
        .onChange(of: atem.state.preview[booth.me]) { _, _ in viewingLive = nil }
        .alert("Rename shot", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Pulpit", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.shot.name ?? "this shot")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let d = deleting, let i = ptz.cameras.firstIndex(where: { $0.id == d.camera }) {
                    ptz.cameras[i].shots.removeAll { $0.id == d.shot.id }
                    ShotPictures.shared.remove(d.shot.id)
                }
                deleting = nil
            }
        }
        .confirmationDialog(presetQuestion, isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } })) {
            Button("Delete from camera", role: .destructive) {
                if let d = deletingPreset {
                    ptz.deleteCameraPreset(d.n, camera: d.camera) { why in
                        if let why { problem = "Couldn't delete that preset. \(why)" }
                    }
                }
                deletingPreset = nil
            }
        } message: {
            Text("This removes it from the camera itself, for every controller that uses it. It can't be undone.")
        }
        .confirmationDialog(liveQuestion, isPresented: Binding(get: { liveMove != nil }, set: { if !$0 { liveMove = nil } })) {
            Button("Move it on Live", role: .destructive) { liveMove?.run(); liveMove = nil }
        } message: {
            Text("Everyone watching will see the camera move.")
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    func note(_ s: String) -> some View {
        Text(s).font(.sans(13)).foregroundStyle(T.inkSubtle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: T.rMD).stroke(T.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    // MARK: Tabs

    var tabs: some View {
        HStack(spacing: Self.gap) {
            ForEach(cams) { c in tab(c) }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }

    func tab(_ c: PTZCamera) -> some View {
        let live = onLive(c), next = onNext(c), open = shown?.id == c.id
        let count = deck.items(c, ptz).count
        return Button {
            if live { viewingLive = c.id }
            else if let i = c.atemInput { viewingLive = nil; atem.setPreview(i, me: booth.me) }
        } label: {
            HStack(spacing: 6) {
                Text(c.name).font(.sans(13, .bold)).lineLimit(1)
                if live || next {
                    Text(live ? "LIVE" : "NEXT").font(.sans(9, .bold)).tracking(0.8).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(live ? T.program : T.preview))
                }
                Text("\(count)").font(.sans(11, .semibold)).monospacedDigit().foregroundStyle(T.inkSubtle)
            }
            .foregroundStyle(open ? T.ink : T.inkMuted)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: T.rMD).fill(open ? T.surfaceRaised : T.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: T.rMD)
                .stroke(live ? T.program : (next ? T.preview : T.line), lineWidth: open && (live || next) ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(live ? "\(c.name) is on Live. Show its shots (they ask before moving it)." : "Put \(c.name) on Next")
    }

    func liveBanner(_ c: PTZCamera) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(c.name) is on Live. A shot here moves it on air, so each one asks first.")
        }
        .font(.sans(11, .semibold)).foregroundStyle(T.program)
    }

    // MARK: Grid

    func grid(_ c: PTZCamera) -> some View {
        let items = deck.items(c, ptz)
        let page = deck.page(of: c, ptz), per = ShotDeckState.perPage, cols = ShotDeckState.columns
        let start = page * per
        let canSave = ptz.canSaveShots(c)
        let nShots = items.filter { !$0.isPreset }.count
        let live = onLive(c)
        return GeometryReader { g in
            let w = (g.size.width - Self.gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (g.size.height - Self.gap * CGFloat(ShotDeckState.rows - 1)) / CGFloat(ShotDeckState.rows)
            let size = CGSize(width: w + Self.gap, height: h + Self.gap)
            ZStack(alignment: .topLeading) {
                ForEach(0..<per, id: \.self) { slot in
                    let i = start + slot
                    let at = CGPoint(x: CGFloat(slot % cols) * size.width, y: CGFloat(slot / cols) * size.height)
                    Group {
                        if i < items.count {
                            let item = items[i]
                            // Shots and the camera's presets each move within their own run on this page.
                            let run = item.isPreset ? (max(nShots, start) - start)...(min(items.count, start + per) - 1 - start)
                                                    : 0...(min(nShots, start + per) - 1 - start)
                            let shotID: UUID? = { if case .shot(let s) = item { s.id } else { nil } }()
                            DeckTile(item: item, letter: ShotDeckState.letters[slot], used: deck.lastUsed[c.id] == item.key,
                                     live: live, canDrag: run.count > 1,
                                     picture: shotID.flatMap { pictures.image($0) },
                                     taking: shotID.map { pictures.taking.contains($0) } ?? false) {
                                go(c) { deck.go(item, camera: c, ptz) }
                            } onLift: {
                                drag = ShotDrag(camera: c.id, page: page, from: slot, range: run, cell: size)
                            } onDrag: { drag?.moved = $0 } onDrop: { drop(c) }
                            .contextMenu { menu(item, c) }
                            .modifier(ShotPlace(drag: drag, camera: c.id, page: page, slot: slot))
                        } else if i == items.count, canSave {
                            saveTile(c)
                        } else {
                            RoundedRectangle(cornerRadius: T.rMD).fill(T.surfaceSunken.opacity(0.5))
                        }
                    }
                    .frame(width: w, height: h)
                    .offset(x: at.x, y: at.y)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder func menu(_ item: DeckItem, _ c: PTZCamera) -> some View {
        switch item {
        case .shot(let s):
            Button("Update to where the camera is now (and its picture)") {
                ptz.saveShot("", camera: c.id, kind: s.kind, replacing: s.id) { if !$0 { problem = Self.noReading } }
            }
            Button("Rename…") { newName = s.name; renaming = (c.id, s) }
            Divider()
            Button("Delete…") { deleting = (c.id, s) }
        case .preset(let n, _):
            if ptz.canSaveShots(c) { Button("Delete from camera…") { deletingPreset = (c.id, n) } }
        }
    }

    func saveTile(_ c: PTZCamera) -> some View {
        Button { newName = ""; saving = true } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                Text("Save where \(c.name) is").font(.sans(12, .semibold)).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(T.accentStrong).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: T.rMD).stroke(T.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Save where \(c.name) is pointing now as a new shot")
        .popover(isPresented: $saving, arrowEdge: .top) { savePopover(c) }
    }

    // MARK: Pager

    func pager(_ c: PTZCamera) -> some View {
        let pages = deck.pages(c, ptz), page = deck.page(of: c, ptz)
        return HStack(spacing: T.s2) {
            Button { deck.turn(c, by: -1, ptz) } label: { arrow("chevron.left", on: page > 0) }
                .buttonStyle(PressStyle()).disabled(page == 0).help("Previous page ([)")
            HStack(spacing: 5) {
                ForEach(0..<pages, id: \.self) { p in
                    Circle().fill(p == page ? T.accent : T.lineStrong).frame(width: 6, height: 6)
                        .onTapGesture { deck.page[c.id] = p }
                }
            }
            Button { deck.turn(c, by: 1, ptz) } label: { arrow("chevron.right", on: page < pages - 1) }
                .buttonStyle(PressStyle()).disabled(page >= pages - 1).help("Next page (])")
            Text("Page \(page + 1) of \(pages)").font(.sans(11, .semibold)).foregroundStyle(T.inkSubtle)
            Spacer()
            Text("Keys Q–K send \(c.name) to a shot").font(.sans(11)).foregroundStyle(T.inkSubtle)
        }
        .frame(height: 22)
        .opacity(pages > 1 ? 1 : 0.6)
    }

    func arrow(_ icon: String, on: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 11, weight: .bold))
            .foregroundStyle(on ? T.ink : T.inkSubtle.opacity(0.5))
            .frame(width: 30, height: 22)
            .background(RoundedRectangle(cornerRadius: T.rSM).fill(T.surfaceRaised))
            .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Moves a camera, asking first if it's on Live.
    func go(_ c: PTZCamera, _ run: @escaping () -> Void) {
        if onLive(c) { liveMove = (c.id, run) } else { run() }
    }

    /// Puts the dragged shot down where it was dropped, and saves the new order.
    func drop(_ c: PTZCamera) {
        defer { drag = nil }
        guard let d = drag, d.to != d.from, let ci = ptz.cameras.firstIndex(where: { $0.id == d.camera }) else { return }
        let items = deck.items(ptz.cameras[ci], ptz)
        let from = d.page * ShotDeckState.perPage + d.from, to = d.page * ShotDeckState.perPage + d.to
        guard from < items.count, to < items.count, items[from].isPreset == items[to].isPreset else { return }
        if items[from].isPreset {
            let nShots = items.filter { !$0.isPreset }.count
            var list = ShotDeckState.presets(ptz.cameras[ci], ptz)
            list.insert(list.remove(at: from - nShots), at: to - nShots)
            ptz.cameras[ci].presetOrder = list
        } else {
            // Exposure shots share the list: reorder the position shots within the places they hold.
            var all = ptz.cameras[ci].shots
            let slots = all.indices.filter { all[$0].kind == .position }
            var list = slots.map { all[$0] }
            list.insert(list.remove(at: from), at: to)
            for (k, i) in slots.enumerated() { all[i] = list[k] }
            ptz.cameras[ci].shots = all
        }
    }

    var liveQuestion: String {
        guard let id = liveMove?.camera, let c = ptz.cameras.first(where: { $0.id == id }) else { return "Move the live camera?" }
        return "\(c.name) is on Live. Move it anyway?"
    }

    var presetQuestion: String {
        guard let d = deletingPreset, let c = ptz.cameras.first(where: { $0.id == d.camera }) else { return "Delete this preset?" }
        return "Delete \"\(ptz.presetNames(c)[d.n] ?? "Preset \(d.n)")\" from \(c.name)?"
    }

    func savePopover(_ t: PTZCamera) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text("Save a shot on \(t.name)").font(.sans(14, .bold))
            Text("Pan, tilt and zoom, where the camera is pointing now.")
                .font(.sans(12)).foregroundStyle(T.inkMuted)
            TextField("Pulpit", text: $newName)
                .textFieldStyle(.roundedBorder).onSubmit { save(t) }
            HStack {
                Spacer()
                Button("Cancel") { saving = false }.keyboardShortcut(.cancelAction)
                Button("Save") { save(t) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(T.s4)
        .frame(width: 300)
    }

    func save(_ t: PTZCamera) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        ptz.saveShot(name, camera: t.id, kind: .position) { if !$0 { problem = Self.noReading } }
        saving = false
    }

    func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let r = renaming, !name.isEmpty,
           let i = ptz.cameras.firstIndex(where: { $0.id == r.camera }), let j = ptz.cameras[i].shots.firstIndex(where: { $0.id == r.shot.id }) {
            ptz.cameras[i].shots[j].name = name
        }
        renaming = nil
    }
}

/// A tile being dragged to a new place on its page: where it started, and how far it has been carried.
struct ShotDrag: Equatable {
    var camera: UUID
    var page: Int
    var from: Int
    /// The slots it may land on: its own run (saved shots, or the camera's presets) on this page.
    var range: ClosedRange<Int>
    /// A tile plus the gap to the next one, across and down.
    var cell: CGSize
    var moved: CGSize = .zero

    static let columns = ShotDeckState.columns

    /// The slot it would land in if dropped now.
    var to: Int {
        let col = min(Self.columns - 1, max(0, from % Self.columns + Int((moved.width / cell.width).rounded())))
        let row = min(ShotDeckState.rows - 1, max(0, from / Self.columns + Int((moved.height / cell.height).rounded())))
        return min(range.upperBound, max(range.lowerBound, row * Self.columns + col))
    }

    func spot(_ slot: Int) -> CGPoint {
        CGPoint(x: CGFloat(slot % Self.columns) * cell.width, y: CGFloat(slot / Self.columns) * cell.height)
    }

    /// How far the tile in `slot` sits from its usual place: the dragged one follows the mouse,
    /// the ones it passes step along to make room.
    func shift(_ slot: Int) -> CGSize {
        if slot == from { return moved }
        let dest = from < slot && slot <= to ? slot - 1 : (to <= slot && slot < from ? slot + 1 : slot)
        let a = spot(slot), b = spot(dest)
        return CGSize(width: b.x - a.x, height: b.y - a.y)
    }
}

/// Moves a tile while a drag on its page is under way.
struct ShotPlace: ViewModifier {
    let drag: ShotDrag?
    let camera: UUID
    let page: Int
    let slot: Int

    func body(content: Content) -> some View {
        let d = drag.flatMap { $0.camera == camera && $0.page == page && $0.range.contains(slot) ? $0 : nil }
        let mine = d?.from == slot
        content
            .offset(d?.shift(slot) ?? .zero)
            .zIndex(mine ? 1 : 0)
            .animation(mine || d == nil ? nil : .easeOut(duration: 0.15), value: d?.to)
    }
}

/// One shot in the deck: its key, its name, and whether it's where the camera was last sent.
/// A click sends the camera there. Held for a moment it lifts, and can be dragged to a new place.
struct DeckTile: View {
    let item: DeckItem
    let letter: String
    let used: Bool
    let live: Bool
    let canDrag: Bool
    /// The shot's saved picture, taken when it was saved or last updated.
    var picture: NSImage? = nil
    /// Its picture is being taken now.
    var taking = false
    let action: () -> Void
    let onLift: () -> Void
    let onDrag: (CGSize) -> Void
    let onDrop: () -> Void

    @State private var press: UUID?
    @State private var lifted = false
    @State private var strayed = false

    var body: some View {
        ZStack {
            if let picture {
                // The picture fills the tile; the name sits on a dark strip along the bottom.
                // Over a clear frame, so a picture wider or taller than the tile is cropped
                // rather than making the tile bigger.
                Color.clear
                    .overlay { Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        Text(item.name).font(.sans(11, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity).background(Color.black.opacity(0.65))
                    }
            } else {
                Text(item.name).font(.sans(13, .bold)).lineLimit(2).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            if taking { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: T.rMD))
        .overlay(alignment: .topLeading) {
            Text(letter).font(.sans(10, .bold)).monospaced()
                .foregroundStyle(picture != nil ? .white : (used ? T.onAction : T.inkMuted))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(picture != nil ? Color.black.opacity(0.6) : .clear))
                .background(RoundedRectangle(cornerRadius: 3).stroke(used ? T.onAction.opacity(0.5) : T.lineStrong))
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            if used {
                Text("HERE").font(.sans(9, .bold)).tracking(0.8).foregroundStyle(T.onAction)
                    .padding(.horizontal, picture != nil ? 4 : 0).padding(.vertical, picture != nil ? 1 : 0)
                    .background(Capsule().fill(picture != nil ? T.accent : .clear))
                    .padding(picture != nil ? 5 : 7)
            }
        }
        .overlay(alignment: .bottom) {
            if item.isPreset {
                Text("ON CAMERA").font(.sans(8, .bold)).tracking(0.6).opacity(0.6).padding(.bottom, 5)
            }
        }
        .foregroundStyle(used ? T.onAction : T.ink)
        .background(RoundedRectangle(cornerRadius: T.rMD).fill(used ? T.accent : T.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: T.rMD).stroke(lifted || used ? T.accent : (live ? T.program.opacity(0.5) : T.line),
                                                              lineWidth: lifted || (used && picture != nil) ? 3 : 1))
        .opacity(lifted ? 1 : (press != nil && !strayed ? 0.7 : (live && !used ? 0.75 : 1)))
        .scaleEffect(lifted ? 1.05 : 1)
        .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: lifted)
        .contentShape(Rectangle())
        // Measured against the window, since the tile itself moves under the mouse.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if press == nil {
                    let id = UUID()
                    press = id; strayed = false
                    guard canDrag else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        guard press == id, !strayed else { return }
                        lifted = true
                        onLift()
                    }
                }
                if lifted { onDrag(v.translation) }
                else if hypot(v.translation.width, v.translation.height) > 8 { strayed = true }
            }
            .onEnded { _ in
                if lifted { onDrop() } else if !strayed { action() }
                press = nil; lifted = false; strayed = false
            })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .help(canDrag ? "Click (or press \(letter)) to go to this shot. Hold, then drag, to move it." : "Click (or press \(letter)) to go to this shot")
    }
}
