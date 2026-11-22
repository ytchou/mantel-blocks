import BlockKit
import Foundation

/// A Yoink-style shelf. When a drag starts anywhere, the notch opens as a drop
/// target; dropped items stay until they are dragged out or removed. Runs in
/// its own process; the app sends it drags, hover and screenshots, draws the
/// trees it sends, and handles the drag-out and Quick Look.
///
/// What it shows, derived from its state in `desiredMode`:
/// - a drag of another app is in progress: the shelf expanded, taking drops;
/// - its own drag-out is in progress: the shelf expanded, taking no drops, so
///   it stays open while the pointer is outside the notch;
/// - a late drop may still come: see `lateDropGrace`;
/// - it holds items: nothing at rest (or the count beside the notch),
///   expanding on hover; while the pointer is on it, it keeps the notch;
/// - otherwise nothing.
public struct ShelfBlock: Block {
    /// Setting keys, as in `manifest.json`. The app stores them as `shelf.<key>`.
    nonisolated static let showCount = "showCount"
    nonisolated static let collectScreenshots = "collectScreenshots"
    nonisolated static let clearAction = "shelf.clear"

    /// How long a late drop is waited for (see `ShelfSession.lateDropGrace`).
    /// It must stay below the app's `Arbiter.interactionWindow` (20 s, in
    /// NotchCore): the wait keeps an `interactive` presentation, which the
    /// arbiter lets hold the notch only that long. A test checks it.
    nonisolated static let defaultLateDropGrace: Duration = .seconds(16)

    public var id: String { "shelf" }

    let lateDropGrace: Duration
    let thumbnailer: Thumbnailer

    public init() {
        self.init(lateDropGrace: Self.defaultLateDropGrace, thumbnailer: .system)
    }

    init(lateDropGrace: Duration, thumbnailer: Thumbnailer) {
        self.lateDropGrace = lateDropGrace
        self.thumbnailer = thumbnailer
    }

    public func start(_ ctx: Context) {
        let session = ShelfSession(ctx, lateDropGrace: lateDropGrace, thumbnailer: thumbnailer)
        // Replayed events (after a crash or an update) are history: a drag
        // they report is over, so they present nothing and start no grace.
        ctx.on(.dragStarted) { event in if !event.replay { session.dragStarted() } }
        ctx.on(.dragEnded) { event in if !event.replay { session.dragEnded() } }
        ctx.on(.pointerHover) { event in
            guard let hover = event.pointerHover else { return }
            if event.replay {
                session.pointerHoverReplayed(isInside: hover.isInside)
            } else {
                session.pointerHoverChanged(isInside: hover.isInside)
            }
        }
        // The shelf hears about screenshots from the event source, not from
        // the rename block, so each block works with the other one off. When
        // the rename block renames the file, the item's bookmark follows it.
        ctx.on(.screenshotCaptured) { event in
            guard let shot = event.screenshot, !event.replay else { return }
            session.screenshotCaptured(shot.url)
        }
        ctx.onDrop { session.dropped($0) }
        ctx.onItem { id, action in session.itemAction(id, action) }
        ctx.onInput { session.input($0) }
        ctx.onDragBegan { session.beginDragOut($0) }
        ctx.onDragEnded { id, succeeded in session.endDragOut(id, succeeded: succeeded) }
        ctx.onOwnerChanged { session.ownerChanged($0) }
        ctx.onAction { id in if id == ShelfBlock.clearAction { session.clear() } }
        ctx.onSettingChanged { key, _ in if key == ShelfBlock.showCount { session.presentAgain() } }
        session.activate()
    }
}

/// One run of the block: the store, the state machine and the trees sent.
@MainActor
final class ShelfSession {
    enum Mode: Equatable {
        case none
        case dropTarget
        case dragOut
        case receiving
        case ambient
        /// Holding items, with the pointer on the open shelf.
        case browsing
    }

    static let acceptedKinds: [DragStarted.Kind] = [.file, .link, .text]

    let store: ShelfStore
    private let ctx: Context
    private(set) var mode: Mode = .none
    private lazy var thumbnails = Thumbnails(
        thumbnailer: thumbnailer,
        makeNode: { [unowned self] in self.ctx.image($0, size: Thumbnails.side) },
        onChange: { [weak self] in self?.refresh() }
    )
    private let thumbnailer: Thumbnailer

    /// Late drops. The app delivers a drop with promised files only after
    /// the files are written, up to 15 s after the mouse-up, and forwards a
    /// drop only to the block that owns the notch. So when a drag ends with
    /// the pointer over the notch and no drop has arrived yet, the shelf
    /// keeps an interactive presentation that takes drops for this long, a
    /// little over the app's 15 s limit, or until the drop arrives. Below
    /// the app's `Arbiter.interactionWindow` (20 s), which bounds how long an
    /// interactive presentation keeps the notch: `ShelfBlock.defaultLateDropGrace`.
    private let lateDropGrace: Duration

    private var pointerInside = false
    /// The pointer is on the shelf while the shelf is what the notch shows.
    private var isBrowsing = false
    /// Another app's drag is in progress.
    private var isDragActive = false
    /// The shelf's own drag-out is in progress.
    private var isDraggingOut = false
    /// The drag session the monitor reported was the shelf's own drag-out.
    private var ownDragSession = false
    private var droppedThisSession = false
    private var graceTask: Task<Void, Never>?
    /// The stack shown as single items, if any.
    private var expandedStackID: UUID?
    /// The trees the app holds, so an unchanged view is not sent again.
    private var sentWing: ViewNode?
    private var sentExpanded: ViewNode?
    /// Whether "Clear Shelf" was last sent enabled.
    private var sentClearEnabled: Bool?

    init(_ ctx: Context, lateDropGrace: Duration, thumbnailer: Thumbnailer) {
        self.ctx = ctx
        self.lateDropGrace = lateDropGrace
        self.thumbnailer = thumbnailer
        store = ShelfStore(directory: ctx.dataFolder)
    }

    func activate() {
        store.pruneMissing()
        mode = .none
        refresh()
    }

    // MARK: Settings

    /// Show the item count beside the notch. Off unless turned on.
    private var showCount: Bool { ctx.bool(ShelfBlock.showCount) ?? false }
    /// Add each new screenshot to the shelf. On unless turned off.
    private var collectScreenshots: Bool { ctx.bool(ShelfBlock.collectScreenshots) ?? true }

    // MARK: Events

    func pointerHoverChanged(isInside: Bool) {
        pointerInside = isInside
        // In use only when the shelf is what the pointer landed on, not
        // when it landed on another block's presentation.
        isBrowsing = isInside && ctx.ownsNotch
        refresh()
    }

    /// Where the pointer was, from a replayed hover. State only: nothing is
    /// presented until a live event or ownership change calls for it.
    func pointerHoverReplayed(isInside: Bool) {
        pointerInside = isInside
    }

    /// The app says ownership after a present, so it may come after the
    /// hover that it answers: the shelf getting the notch under the pointer
    /// is in use. Losing the notch ends browsing: the pointer is on another
    /// block's presentation.
    func ownerChanged(_ owns: Bool) {
        guard owns else {
            guard isBrowsing else { return }
            isBrowsing = false
            refresh()
            return
        }
        guard pointerInside, !isBrowsing else { return }
        isBrowsing = true
        refresh()
    }

    func screenshotCaptured(_ url: URL) {
        guard collectScreenshots else { return }
        // Held by reference: the file stays where macOS saved it.
        store.add([.file(url)])
        refresh()
    }

    func dragStarted() {
        if isDraggingOut {
            ownDragSession = true
            return
        }
        isDragActive = true
        droppedThisSession = false
        endGrace()
        store.pruneMissing()
        refresh()
    }

    func dragEnded() {
        if ownDragSession {
            ownDragSession = false
            refresh()
            return
        }
        guard isDragActive else { return }
        isDragActive = false
        if pointerInside && !droppedThisSession { startGrace() }
        refresh()
    }

    func dropped(_ items: [WireDrop]) {
        store.add(items.compactMap(DroppedItem.init))
        droppedThisSession = true
        endGrace()
        refresh()
    }

    private func startGrace() {
        graceTask?.cancel()
        let grace = lateDropGrace
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            self.graceTask = nil
            self.refresh()
        }
    }

    private func endGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    // MARK: View input

    func input(_ input: WireInput) {
        guard case let .button(id) = input else { return }
        switch id {
        case "clear":
            clear()
        case "back":
            expandedStackID = nil
            refresh()
        default:
            guard id.hasPrefix("remove:"), let target = ShelfTarget(wireID: String(id.dropFirst("remove:".count))) else { return }
            remove(target)
        }
    }

    func itemAction(_ id: String, _ action: ItemAction) {
        guard let target = ShelfTarget(wireID: id) else { return }
        switch action {
        case .click:
            toggleExpanded(target)
        case .doubleClick, .menu(id: "quickLook"):
            quickLook(target)
        case .menu(id: "showItems"):
            toggleExpanded(target)
        case .menu(id: "remove"):
            remove(target)
        case .menu:
            break
        }
    }

    private func toggleExpanded(_ target: ShelfTarget) {
        guard case let .stack(id) = target, store.items(for: target).count > 1 else { return }
        expandedStackID = expandedStackID == id ? nil : id
        refresh()
    }

    func remove(_ target: ShelfTarget) {
        store.remove(target)
        refresh()
    }

    func clear() {
        store.clear()
        refresh()
    }

    private func quickLook(_ target: ShelfTarget) {
        let paths = store.items(for: target).compactMap { store.fileURL(of: $0)?.path(percentEncoded: false) }
        if !paths.isEmpty { ctx.preview(paths: paths) }
    }

    /// The app started dragging a tile out. It comes before the monitor's
    /// `dragStarted` for the same drag, which is then recognised as the
    /// shelf's own.
    func beginDragOut(_ id: String) {
        guard ShelfTarget(wireID: id) != nil else { return }
        isDraggingOut = true
        refresh()
    }

    /// The drag-out ended. A drop elsewhere takes the items off the shelf; a
    /// cancelled or refused drop leaves them.
    func endDragOut(_ id: String, succeeded: Bool) {
        isDraggingOut = false
        if succeeded, let target = ShelfTarget(wireID: id) {
            // Owned files stay on disk until the next launch's sweep: the
            // receiving app may still be reading them.
            store.remove(target, deleteOwnedFiles: false)
        }
        refresh()
    }

    // MARK: Presentation

    private var desiredMode: Mode {
        if isDraggingOut { return .dragOut }
        if isDragActive { return .dropTarget }
        if graceTask != nil { return .receiving }
        if store.isEmpty { return .none }
        return isBrowsing ? .browsing : .ambient
    }

    /// Brings the notch in line with the state. Presents only when the mode
    /// changes; otherwise sends the trees again when they changed, as the
    /// in-app views followed the store.
    func refresh() {
        if let expanded = expandedStackID, store.stack(expanded) == nil { expandedStackID = nil }
        sendActions()

        let next = desiredMode
        if next != mode {
            mode = next
            present(next)
        } else if mode != .none {
            update()
        }
    }

    /// Presents the current mode again, after a setting changed.
    func presentAgain() {
        guard mode != .none else { return }
        present(mode)
    }

    private func present(_ mode: Mode) {
        guard mode != .none else {
            sentWing = nil
            sentExpanded = nil
            ctx.dismiss()
            return
        }
        let expanded = ViewSlot(width: ShelfTrees.width, height: ShelfTrees.height, root: expandedTree())
        let wing = hasWing(mode) ? wingSlot() : nil
        sentExpanded = expanded.root
        sentWing = wing?.root
        switch mode {
        case .none:
            break
        case .dropTarget:
            ctx.present(expanded: expanded, priority: .interactive, opensAt: .expanded, accepts: Self.acceptedKinds)
        case .dragOut:
            ctx.present(expanded: expanded, priority: .interactive, opensAt: .expanded)
        case .receiving:
            ctx.present(wing: wing, expanded: expanded, priority: .interactive, opensAt: .peek, accepts: Self.acceptedKinds)
        case .browsing:
            // Interactive while in use, so another block's news (a renamed
            // screenshot) waits until the pointer leaves, instead of
            // replacing the shelf under the pointer.
            ctx.present(wing: wing, expanded: expanded, priority: .interactive, opensAt: .peek, accepts: Self.acceptedKinds)
        case .ambient:
            // Takes drops too, so a promise that outlives the grace period is
            // still kept while the shelf owns the notch.
            ctx.present(wing: wing, expanded: expanded, priority: .ambient, opensAt: .peek, accepts: Self.acceptedKinds)
        }
    }

    /// Sends the trees that changed since the last present or update.
    private func update() {
        let expanded = expandedTree()
        let wing = hasWing(mode) ? wingSlot().root : nil
        let newExpanded = expanded == sentExpanded ? nil : expanded
        let newWing = wing == sentWing ? nil : wing
        guard newExpanded != nil || newWing != nil else { return }
        sentExpanded = expanded
        sentWing = wing
        ctx.update(wing: newWing, expanded: newExpanded)
    }

    private func hasWing(_ mode: Mode) -> Bool {
        mode == .receiving || mode == .browsing || mode == .ambient
    }

    /// With the count off, a wing of no width: the shape stays the notch
    /// itself and takes no room, and hovering it still opens the shelf.
    private func wingSlot() -> ViewSlot {
        showCount
            ? ViewSlot(width: ShelfTrees.wingWidth, height: ShelfTrees.wingHeight,
                       root: ShelfTrees.wing(itemCount: store.itemCount, isReceiving: graceTask != nil))
            : ViewSlot(width: 0, height: 0, root: ShelfTrees.emptyWing)
    }

    private func sendActions() {
        let enabled = !store.isEmpty
        guard enabled != sentClearEnabled else { return }
        sentClearEnabled = enabled
        ctx.setActions([ActionItem(id: ShelfBlock.clearAction, title: "Clear Shelf", enabled: enabled)])
    }

    // MARK: Trees

    private func expandedTree() -> ViewNode {
        let shown = expandedStackID.flatMap { store.stack($0) }
        let tiles: [ShelfTrees.Tile]
        if let shown {
            tiles = shown.items.map { tile(.item($0.id), [$0]) }
        } else {
            tiles = store.stacks.map { tile(.stack($0.id), $0.items) }
        }
        return ShelfTrees.expanded(ShelfTrees.State(
            itemCount: store.itemCount,
            isDropTarget: isDragActive,
            isReceiving: graceTask != nil,
            shownStackCount: shown?.items.count,
            tiles: tiles
        ))
    }

    private func tile(_ target: ShelfTarget, _ items: [ShelfItem]) -> ShelfTrees.Tile {
        let first = items.first
        var dragImage: String?
        let preview: ViewNode
        switch first?.content {
        case .file?:
            if let url = first.flatMap({ store.fileURL(of: $0) }) {
                let picture = thumbnails.picture(for: url)
                dragImage = picture?.asset
                preview = ShelfTrees.file(picture?.node)
            } else {
                preview = ShelfTrees.missingFile
            }
        case let .link(url)?:
            preview = ShelfTrees.link(url)
        case let .text(text)?:
            preview = ShelfTrees.text(text)
        case nil:
            preview = ShelfTrees.missingFile
        }
        return ShelfTrees.Tile(
            id: target.wireID,
            title: first.map { store.displayName(of: $0) } ?? "",
            preview: preview,
            count: items.count,
            hasFiles: items.contains(where: \.isFile),
            drag: ViewNode.ItemDrag(items.compactMap(dragEntry), image: dragImage),
            isStack: items.count > 1
        )
    }

    /// The drag entry of one item: a file path, a link or a string.
    private func dragEntry(_ item: ShelfItem) -> WireDrop? {
        switch item.content {
        case .file:
            store.fileURL(of: item).map { .file(path: $0.path(percentEncoded: false)) }
        case let .link(url):
            .link(url: url.absoluteString)
        case let .text(text):
            .text(string: text)
        }
    }
}

// MARK: - Wire ids and drops

extension ShelfTarget {
    /// The `item` id: `stack:<uuid>` or `item:<uuid>`.
    var wireID: String {
        switch self {
        case let .stack(id): "stack:\(id.uuidString)"
        case let .item(id): "item:\(id.uuidString)"
        }
    }

    init?(wireID: String) {
        let parts = wireID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "stack": self = .stack(id)
        case "item": self = .item(id)
        default: return nil
        }
    }
}

extension DroppedItem {
    /// A drop from the app. Nil for a link that is not a URL.
    init?(_ drop: WireDrop) {
        switch drop {
        case let .file(path): self = .file(URL(fileURLWithPath: path))
        case let .link(string):
            guard let url = URL(string: string) else { return nil }
            self = .link(url)
        case let .text(string): self = .text(string)
        }
    }
}

extension ShelfStore {
    /// Name under a tile: the file name, a link's host, a text's first line.
    func displayName(of item: ShelfItem) -> String {
        switch item.content {
        case let .file(path, _, _):
            return (fileURL(of: item) ?? URL(filePath: path)).lastPathComponent
        case let .link(url):
            return url.host() ?? url.absoluteString
        case let .text(text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces)
        }
    }
}
