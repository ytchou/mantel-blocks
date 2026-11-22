import BlockKit
import BlockKitTesting
import Foundation
import Testing
@testable import ShelfCore

// The block's behaviour, ported from the in-app block's tests. Each test runs
// the block over `FakeHost`, as the app would, and checks the messages it
// sends and the index it saves in its data folder.

// MARK: - Helpers

/// A running block and its data folder.
private struct Run {
    let host: FakeHost
    let folder: URL
}

/// A block welcomed with `settings`, storing in `folder` (a new one when nil).
@MainActor
private func start(
    settings: [String: SettingValue] = [:],
    folder: URL? = nil,
    lateDropGrace: Duration = .seconds(60),
    thumbnailer: Thumbnailer = .none
) async throws -> Run {
    let folder = try folder ?? makeTemporaryDirectory()
    let host = FakeHost()
    host.run(ShelfBlock(lateDropGrace: lateDropGrace, thumbnailer: thumbnailer))
    try await host.welcome(settings: settings, dataFolder: folder.path(percentEncoded: false))
    try await send(host)
    return Run(host: host, folder: folder)
}

/// Sends `messages`, then waits until the block has handled them: the kit
/// answers a ping on the main queue after every message sent before it.
private func send(_ host: FakeHost, _ messages: HostToBlock...) async throws {
    for message in messages { try host.send(message) }
    let seq = host.received.filter(isPong).count + 1
    try host.send(.ping(seq: seq))
    _ = await host.waitFor { $0 == .pong(seq: seq) }
}

private func isPong(_ message: BlockToHost) -> Bool { if case .pong = message { true } else { false } }

private func dragStarted(_ kinds: [DragStarted.Kind] = [.file]) -> HostToBlock {
    .event(payload: .dragStarted(.init(kinds: kinds)), replay: false)
}

private let dragEnded = HostToBlock.event(payload: .dragEnded, replay: false)

private func hover(_ isInside: Bool) -> HostToBlock {
    .event(payload: .pointerHover(.init(isInside: isInside)), replay: false)
}

private func drop(_ items: [WireDrop]) -> HostToBlock {
    .input(input: .drop(items: items))
}

private func screenshot(_ url: URL) -> HostToBlock {
    .event(payload: .screenshotCaptured(.init(path: url.path(percentEncoded: false), createdAt: Date().timeIntervalSince1970)), replay: false)
}

private let owns = HostToBlock.owner(owns: true)
private let ownsNot = HostToBlock.owner(owns: false)

/// `message` as the app sends it again after the block restarted.
private func replayed(_ message: HostToBlock) -> HostToBlock {
    guard case let .event(payload, _, seq) = message else { return message }
    return .event(payload: payload, replay: true, seq: seq)
}

/// Runs one external drag that drops `items` on the notch.
private func dragAndDrop(_ items: [WireDrop], on run: Run) async throws {
    try await send(run.host, dragStarted(), drop(items), dragEnded)
}

private let exampleURL = "https://example.com/page"

/// What the app would show for the block now: the last `present`, with the
/// trees of later `update`s, or nil after a `dismiss`.
private struct Shown {
    var priority: Priority
    var wing: ViewSlot?
    var expanded: ViewSlot?
    var peek: ViewSlot?
    var opensAt: Level
    var seconds: Double?
    var accepts: [DragStarted.Kind]?
}

private func shown(_ host: FakeHost) -> Shown? {
    var current: Shown?
    for message in host.received {
        switch message {
        case let .present(priority, peek, wing, expanded, opensAt, seconds, _, accepts, _):
            current = Shown(priority: priority, wing: wing, expanded: expanded, peek: peek,
                            opensAt: opensAt, seconds: seconds, accepts: accepts)
        case let .update(peek, wing, expanded):
            if let peek { current?.peek?.root = peek }
            if let wing { current?.wing?.root = wing }
            if let expanded { current?.expanded?.root = expanded }
        case .dismiss:
            current = nil
        default:
            break
        }
    }
    return current
}

private func expandedRoot(_ shown: Shown?) -> ViewNode? { shown?.expanded?.root }

private func presentCount(_ host: FakeHost) -> Int {
    host.received.filter { if case .present = $0 { true } else { false } }.count
}

/// The stacks the block saved, newest first.
private func stored(_ run: Run) throws -> [ShelfStack] {
    let url = run.folder.appending(path: "index.json")
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
    return try JSONDecoder().decode([ShelfStack].self, from: Data(contentsOf: url))
}

private func storedCount(_ run: Run) throws -> Int {
    try stored(run).reduce(0) { $0 + $1.items.count }
}

private func nodes(_ node: ViewNode) -> [ViewNode] {
    [node] + node.children.flatMap(nodes)
}

private func texts(_ node: ViewNode?) -> [String] {
    guard let node else { return [] }
    return nodes(node).compactMap { node in
        switch node.kind {
        case let .text(text, _): text
        case let .styledText(runs, _): runs.map(\.text).joined()
        default: nil
        }
    }
}

private struct ItemNode {
    let id: String
    let drag: ViewNode.ItemDrag?
    let menu: [ActionItem]
    let click: Bool
    let doubleClick: Bool
    let child: ViewNode
    let overlay: ViewNode?
}

private func items(_ node: ViewNode?) -> [ItemNode] {
    guard let node else { return [] }
    return nodes(node).compactMap { node in
        if case let .item(id, child, _, _, drag, menu, click, doubleClick, _, overlay) = node.kind {
            ItemNode(id: id, drag: drag, menu: menu ?? [], click: click == true, doubleClick: doubleClick == true,
                     child: child, overlay: overlay)
        } else { nil }
    }
}

private func buttons(_ node: ViewNode?) -> [String] {
    guard let node else { return [] }
    return nodes(node).compactMap { node in
        if case let .button(id, _, _, _, _, _, _, _, _) = node.kind { id } else { nil }
    }
}

private func hasSpinner(_ node: ViewNode?) -> Bool {
    guard let node else { return false }
    return nodes(node).contains { if case .spinner = $0.kind { true } else { false } }
}

private func hasImage(_ node: ViewNode?) -> Bool {
    guard let node else { return false }
    return nodes(node).contains { if case .image = $0.kind { true } else { false } }
}

private func lastActions(_ host: FakeHost) -> [ActionItem]? {
    host.received.compactMap { if case let .actions(items) = $0 { items } else { nil } }.last
}

private let allKinds: [DragStarted.Kind] = [.file, .link, .text]

// MARK: - Ported from the in-app block

@MainActor
@Test func anEmptyShelfShowsNothing() async throws {
    let run = try await start()
    #expect(presentCount(run.host) == 0)
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func aDragOpensTheShelfExpandedAsADropTarget() async throws {
    let run = try await start()
    try await send(run.host, dragStarted())

    let now = try #require(shown(run.host))
    #expect(now.opensAt == .expanded)
    #expect(now.priority == .interactive)
    #expect(now.accepts == allKinds)
    #expect(now.seconds == nil)
    #expect(texts(expandedRoot(now)).contains("Drop here"))
}

@MainActor
@Test func aDropAddsTheItemsAsOneStack() async throws {
    let run = try await start()
    try await send(run.host, dragStarted([.link, .text]), drop([.text(string: "hello"), .link(url: exampleURL)]))

    #expect(try stored(run).count == 1)
    #expect(try storedCount(run) == 2)
    // Still the drop target until the drag ends.
    #expect(presentCount(run.host) == 1)
    #expect(shown(run.host)?.opensAt == .expanded)
    #expect(items(shown(run.host)?.expanded?.root).count == 1)
}

@MainActor
@Test func aDragEndingWithItemsHeldFallsBackToTheCountPeek() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday."), .link(url: exampleURL)], on: run)

    let now = try #require(shown(run.host))
    #expect(now.opensAt == .peek)
    #expect(now.priority == .ambient)
    #expect(now.wing != nil)
    #expect(now.expanded != nil)
    #expect(now.seconds == nil)
    #expect(try storedCount(run) == 3)
    #expect(!texts(expandedRoot(now)).contains("Drop here"))

    // Hovering the shelf while it owns the notch keeps it: browsing.
    try await send(run.host, owns, hover(true))
    #expect(shown(run.host)?.priority == .interactive)
}

@MainActor
@Test func aDragEndingWithNothingHeldDismisses() async throws {
    let run = try await start()
    try await send(run.host, dragStarted(), dragEnded)
    #expect(presentCount(run.host) == 1)
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func aLateDropAfterReleaseOverTheNotchIsStillAdded() async throws {
    let run = try await start()
    try await send(run.host, dragStarted(), owns, hover(true), dragEnded)

    // Waiting for promised files: still presented, taking drops.
    let waiting = try #require(shown(run.host))
    #expect(waiting.accepts?.contains(.file) == true)
    #expect(waiting.priority == .interactive)
    #expect(hasSpinner(waiting.expanded?.root))

    try await send(run.host, drop([.text(string: "late")]))
    #expect(try storedCount(run) == 1)
    #expect(!hasSpinner(shown(run.host)?.expanded?.root))
    // The pointer is still on the shelf, so it keeps the notch; at rest it is ambient.
    #expect(shown(run.host)?.priority == .interactive)
    try await send(run.host, hover(false))
    #expect(shown(run.host)?.priority == .ambient)
}

@MainActor
@Test func theLateDropWaitEndsAfterTheGracePeriod() async throws {
    let run = try await start(lateDropGrace: .milliseconds(20))
    try await send(run.host, dragStarted(), hover(true), dragEnded)
    #expect(shown(run.host) != nil)

    _ = await run.host.waitFor { $0 == .dismiss }
    #expect(shown(run.host) == nil)
}

/// The late-drop wait keeps an `interactive` presentation, and the app's
/// arbiter (`Arbiter.interactionWindow` in NotchCore, 20 s for every block)
/// lets an interactive presentation keep the notch only that long. The wait
/// must end first, and stay above the app's 15 s limit for promised files.
/// This package cannot import NotchCore, so the window is written out here.
@MainActor
@Test func theLateDropWaitEndsBeforeTheArbiterInteractionWindow() {
    let arbiterInteractionWindow: Duration = .seconds(20) // Arbiter.interactionWindow
    #expect(ShelfBlock.defaultLateDropGrace < arbiterInteractionWindow)
    #expect(ShelfBlock.defaultLateDropGrace > .seconds(15))
    #expect(ShelfBlock().lateDropGrace == ShelfBlock.defaultLateDropGrace)
}

@MainActor
@Test func noLateDropWaitWhenReleasedAwayFromTheNotch() async throws {
    let run = try await start()
    try await send(run.host, dragStarted(), dragEnded)
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func aSuccessfulDragOutTakesTheStackOffTheShelf() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    try await dragAndDrop([.text(string: "keep")], on: run)
    let leaving = try #require(try stored(run).last)
    let leavingID = "stack:\(leaving.id.uuidString)"
    #expect(items(expandedRoot(shown(run.host))).map(\.id).contains(leavingID))

    try await send(run.host, .input(input: .dragBegan(id: leavingID)))
    // The monitor reports the shelf's own drag as a session too.
    try await send(run.host, dragStarted([.text]))
    let dragging = try #require(shown(run.host))
    #expect(dragging.opensAt == .expanded)
    #expect(dragging.priority == .interactive)
    #expect(dragging.accepts == nil)
    #expect(!texts(expandedRoot(dragging)).contains("Drop here"))

    // Stays the drag-out presentation with the pointer outside the notch.
    let presents = presentCount(run.host)
    try await send(run.host, hover(true), hover(false))
    #expect(presentCount(run.host) == presents)

    try await send(run.host, .input(input: .dragEnded(id: leavingID, succeeded: true)), dragEnded)

    #expect(try storedCount(run) == 1)
    #expect(try stored(run).contains { $0.id == leaving.id } == false)
    #expect(shown(run.host)?.opensAt == .peek)
}

@MainActor
@Test func aSuccessfulDragOutOfOneItemLeavesTheRestOfTheStack() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    let item = try #require(try stored(run).first?.items.first)
    let id = "item:\(item.id.uuidString)"

    try await send(run.host, .input(input: .dragBegan(id: id)), .input(input: .dragEnded(id: id, succeeded: true)))

    #expect(try storedCount(run) == 1)
}

@MainActor
@Test func aCancelledDragOutKeepsTheItems() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday")], on: run)
    let stack = try #require(try stored(run).first)
    let id = "stack:\(stack.id.uuidString)"

    try await send(run.host, .input(input: .dragBegan(id: id)), dragStarted([.text]), dragEnded,
                   .input(input: .dragEnded(id: id, succeeded: false)))

    #expect(try storedCount(run) == 1)
    #expect(shown(run.host)?.priority == .ambient)
}

@MainActor
@Test func draggingOutTheLastItemEmptiesTheNotch() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday")], on: run)
    let stack = try #require(try stored(run).first)
    let id = "stack:\(stack.id.uuidString)"

    try await send(run.host, .input(input: .dragBegan(id: id)), .input(input: .dragEnded(id: id, succeeded: true)))
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func clearShelfActionEmptiesItAndDismisses() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .link(url: exampleURL)], on: run)

    let clear = try #require(lastActions(run.host)?.first { $0.id == "shelf.clear" })
    #expect(clear.title == "Clear Shelf")
    #expect(clear.enabled)
    try await send(run.host, .action(id: "shelf.clear"))

    #expect(try stored(run).isEmpty)
    #expect(shown(run.host) == nil)
    let afterClear = try #require(lastActions(run.host)?.first)
    #expect(!afterClear.enabled)
}

@MainActor
@Test func removingTheLastItemFromTheViewDismisses() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday")], on: run)
    let stack = try #require(try stored(run).first)
    let remove = "remove:stack:\(stack.id.uuidString)"
    #expect(buttons(expandedRoot(shown(run.host))).contains(remove))

    try await send(run.host, .input(input: .button(id: remove)))
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func heldItemsShowTheirPeekAfterARelaunch() async throws {
    let first = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: first)
    first.host.close()

    let relaunched = try await start(folder: first.folder)
    let now = try #require(shown(relaunched.host))
    #expect(now.opensAt == .peek)
    #expect(now.priority == .ambient)
}

@MainActor
@Test func aNewScreenshotIsAddedAndFollowsARename() async throws {
    let run = try await start()
    let folder = try makeTemporaryDirectory()
    let shot = try makeFile(named: "Screenshot 1.png", in: folder)

    try await send(run.host, screenshot(shot))
    #expect(try storedCount(run) == 1)
    #expect(shown(run.host) != nil)
    let item = try #require(try stored(run).first?.items.first)
    #expect(item.isOwnedFile == false)

    // What the rename block does: a move inside the same folder.
    let renamed = folder.appending(path: "Login page.png")
    try FileManager.default.moveItem(at: shot, to: renamed)
    #expect(ShelfStore(directory: run.folder).fileURL(of: item)?.lastPathComponent == "Login page.png")

    // Removing the item leaves the user's file alone.
    let stack = try #require(try stored(run).first)
    try await send(run.host, .input(input: .button(id: "remove:stack:\(stack.id.uuidString)")))
    #expect(try stored(run).isEmpty)
    #expect(FileManager.default.fileExists(atPath: renamed.path(percentEncoded: false)))
}

@MainActor
@Test func screenshotsAreNotAddedWhenTheSettingIsOff() async throws {
    let run = try await start(settings: ["collectScreenshots": .bool(false)])
    let shot = try makeFile(named: "Screenshot 2.png", in: try makeTemporaryDirectory())

    try await send(run.host, screenshot(shot))
    #expect(try stored(run).isEmpty)
    #expect(shown(run.host) == nil)
}

@MainActor
@Test func atRestTheShelfTakesNoRoomUnlessTheCountIsTurnedOn() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "hello")], on: run)

    // Holding an item: presented at the peek level, with a wing of no width.
    let rest = try #require(shown(run.host))
    #expect(rest.opensAt == .peek)
    #expect(rest.wing?.width == 0)
    #expect(rest.peek == nil)

    try await send(run.host, .setting(key: "showCount", value: .bool(true)))
    #expect(shown(run.host)?.wing?.width == ShelfTrees.wingWidth)

    // Hovering opens the shelf either way.
    try await send(run.host, .setting(key: "showCount", value: .bool(false)), owns, hover(true))
    #expect(shown(run.host)?.wing?.width == 0)
    #expect(shown(run.host)?.priority == .interactive)
}

// MARK: - New with the package

@MainActor
@Test func replayedDragAndHoverEventsPresentNothing() async throws {
    let run = try await start()
    // A crash mid-drop: the restarted block hears the drag again as replay.
    try await send(run.host, replayed(dragStarted()), replayed(hover(true)), replayed(dragEnded))
    #expect(presentCount(run.host) == 0)
    #expect(shown(run.host) == nil)

    // A live drag afterwards is a drop target as usual.
    try await send(run.host, dragStarted())
    #expect(shown(run.host)?.accepts == allKinds)
}

@MainActor
@Test func replayedEventsDoNotReplaceTheHeldItemsPresentation() async throws {
    let first = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday")], on: first)
    first.host.close()

    let relaunched = try await start(folder: first.folder)
    let presents = presentCount(relaunched.host)
    try await send(relaunched.host, replayed(dragStarted()), replayed(hover(true)), replayed(dragEnded))
    #expect(presentCount(relaunched.host) == presents)
    #expect(shown(relaunched.host)?.priority == .ambient)
}

@MainActor
@Test func losingTheNotchEndsBrowsing() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    try await send(run.host, owns, hover(true))
    #expect(shown(run.host)?.priority == .interactive)

    try await send(run.host, ownsNot)
    #expect(shown(run.host)?.priority == .ambient)

    // Hovering while another block owns the notch does not make it browse.
    try await send(run.host, hover(false), hover(true))
    #expect(shown(run.host)?.priority == .ambient)
}

@MainActor
@Test func modeDecidesPriorityLevelAndAccepts() async throws {
    let run = try await start()

    // Drop target.
    try await send(run.host, dragStarted(), drop([.text(string: "Ship the release notes by Friday")]))
    var now = try #require(shown(run.host))
    #expect(now.priority == .interactive && now.opensAt == .expanded && now.accepts == allKinds && now.wing == nil)

    // Receiving: released over the notch with no drop yet.
    try await send(run.host, dragStarted(), owns, hover(true), dragEnded)
    now = try #require(shown(run.host))
    #expect(now.priority == .interactive && now.opensAt == .peek && now.accepts == allKinds && now.wing != nil)

    // Browsing: the late drop came, the pointer is still on the shelf.
    try await send(run.host, drop([.text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")]))
    now = try #require(shown(run.host))
    #expect(now.priority == .interactive && now.opensAt == .peek && now.accepts == allKinds && now.wing != nil)

    // Ambient: the pointer left.
    try await send(run.host, hover(false))
    now = try #require(shown(run.host))
    #expect(now.priority == .ambient && now.opensAt == .peek && now.accepts == allKinds && now.wing != nil)

    // Drag-out: no drops.
    let stack = try #require(try stored(run).first)
    try await send(run.host, .input(input: .dragBegan(id: "stack:\(stack.id.uuidString)")))
    now = try #require(shown(run.host))
    #expect(now.priority == .interactive && now.opensAt == .expanded && now.accepts == nil && now.wing == nil)
}

@MainActor
@Test func dropAddsItemsAndEndsTheGrace() async throws {
    let run = try await start()
    try await send(run.host, dragStarted(), owns, hover(true), dragEnded)
    #expect(hasSpinner(shown(run.host)?.wing?.root) || hasSpinner(shown(run.host)?.expanded?.root))

    try await send(run.host, drop([.text(string: "kept"), .link(url: exampleURL)]))
    #expect(try storedCount(run) == 2)
    #expect(try stored(run).count == 1)
    let now = try #require(shown(run.host))
    #expect(!hasSpinner(now.expanded?.root))
    #expect(!hasSpinner(now.wing?.root))
    // Browsing now, not receiving: hovering out turns it ambient instead of waiting.
    try await send(run.host, hover(false))
    #expect(shown(run.host)?.priority == .ambient)
}

@MainActor
@Test func dragBeganMarksTheNextDragSessionAsOwn() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday")], on: run)
    try await dragAndDrop([.text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    let stacks = try stored(run)
    let first = "stack:\(try #require(stacks.first).id.uuidString)"
    let second = "stack:\(try #require(stacks.last).id.uuidString)"

    try await send(run.host, .input(input: .dragBegan(id: first)), dragStarted([.text]))
    // Its own drag: no drop target.
    #expect(shown(run.host)?.accepts == nil)
    #expect(!texts(expandedRoot(shown(run.host))).contains("Drop here"))

    // A cancelled drag keeps the items.
    try await send(run.host, .input(input: .dragEnded(id: first, succeeded: false)), dragEnded)
    #expect(try storedCount(run) == 2)

    // A drop elsewhere removes them.
    try await send(run.host, .input(input: .dragBegan(id: second)), dragStarted([.text]),
                   .input(input: .dragEnded(id: second, succeeded: true)), dragEnded)
    #expect(try storedCount(run) == 1)
    #expect(try stored(run).first.map { "stack:\($0.id.uuidString)" } == first)

    // The next drag of another app is a drop target again.
    try await send(run.host, dragStarted())
    #expect(shown(run.host)?.accepts == allKinds)
}

@MainActor
@Test func tileTreeHasDragMenuAndBadge() async throws {
    let run = try await start(thumbnailer: Thumbnailer(icon: { _ in nil }, thumbnail: { _, _ in Data([1, 2, 3]) }))
    let files = try makeTemporaryDirectory("ShelfUserFiles")
    let a = try makeFile(named: "a.txt", in: files)
    let b = try makeFile(named: "b.txt", in: files)
    try await dragAndDrop([.file(path: a.path(percentEncoded: false)), .file(path: b.path(percentEncoded: false))], on: run)
    try await dragAndDrop([.text(string: "note")], on: run)
    // The thumbnail arrives later and comes as an update.
    for _ in 0..<200 where !hasImage(shown(run.host)?.expanded?.root) {
        try await Task.sleep(for: .milliseconds(5))
    }
    try await send(run.host)

    let tree = try #require(shown(run.host)?.expanded?.root)
    let tiles = items(tree)
    #expect(tiles.count == 2)
    let stacks = try stored(run)

    // Newest first: the text, then the two files.
    let text = try #require(tiles.first)
    #expect(text.id == "stack:\(try #require(stacks.first).id.uuidString)")
    #expect(text.drag?.items == [.text(string: "note")])
    #expect(text.menu.map(\.title) == ["Remove"])
    #expect(!text.click && !text.doubleClick)

    let pair = try #require(tiles.last)
    #expect(pair.id == "stack:\(try #require(stacks.last).id.uuidString)")
    #expect(pair.drag?.items.count == 2)
    // Where the bookmarks resolve to: the same files, perhaps under /private.
    let dragged = (pair.drag?.items ?? []).compactMap { drop -> String? in
        if case let .file(path) = drop { URL(filePath: path).lastPathComponent } else { nil }
    }
    #expect(dragged == [a.lastPathComponent, b.lastPathComponent])
    #expect(pair.drag?.image == Assets.id(for: Data([1, 2, 3])))
    #expect(pair.menu.map(\.title) == ["Quick Look", "Show Items", "Remove Stack"])
    #expect(pair.click && pair.doubleClick)
    // The count badge.
    #expect(texts(pair.child).contains("2"))
    // The remove button sits in the item's overlay, not inside its child.
    #expect(buttons(pair.child).isEmpty)
    #expect(buttons(pair.overlay) == ["remove:\(pair.id)"])
    #expect(buttons(tree).contains("clear"))
}

@MainActor
@Test func doubleClickOnAFileAsksForPreview() async throws {
    let run = try await start()
    let file = try makeFile(named: "look.txt", in: try makeTemporaryDirectory("ShelfUserFiles"))
    try await dragAndDrop([.file(path: file.path(percentEncoded: false)), .text(string: "t")], on: run)
    let stack = try #require(try stored(run).first)

    try await send(run.host, .input(input: .item(id: "stack:\(stack.id.uuidString)", action: .doubleClick)))
    let paths = try #require(run.host.previews.last)
    #expect(paths.map { URL(filePath: $0).lastPathComponent } == ["look.txt"])

    // The menu entry does the same.
    try await send(run.host, .input(input: .item(id: "stack:\(stack.id.uuidString)", action: .menu(id: "quickLook"))))
    #expect(run.host.previews.count == 2)
}

@MainActor
@Test func clickOnAStackShowsItsItems() async throws {
    let run = try await start()
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    let stack = try #require(try stored(run).first)
    let stackID = "stack:\(stack.id.uuidString)"

    try await send(run.host, .input(input: .item(id: stackID, action: .click)))
    let tree = try #require(shown(run.host)?.expanded?.root)
    #expect(items(tree).map(\.id) == stack.items.map { "item:\($0.id.uuidString)" })
    #expect(buttons(tree).contains("back"))
    #expect(texts(tree).contains("2 items"))

    // Back shows the stacks again.
    try await send(run.host, .input(input: .button(id: "back")))
    let back = try #require(shown(run.host)?.expanded?.root)
    #expect(items(back).map(\.id) == [stackID])
    #expect(!buttons(back).contains("back"))

    // "Show Items" in the menu does the same as a click.
    try await send(run.host, .input(input: .item(id: stackID, action: .menu(id: "showItems"))))
    #expect(buttons(expandedRoot(shown(run.host))).contains("back"))
}

@MainActor
@Test func showCountOffGivesAZeroWidthWing() async throws {
    let run = try await start(settings: ["showCount": .bool(false)])
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: run)
    let off = try #require(shown(run.host)?.wing)
    #expect(off.width == 0)
    #expect(texts(off.root).isEmpty)

    let on = try await start(settings: ["showCount": .bool(true)])
    try await dragAndDrop([.text(string: "Ship the release notes by Friday"), .text(string: "Dear Ana,\nThanks for the review.\nSee you Monday.")], on: on)
    let wing = try #require(shown(on.host)?.wing)
    #expect(wing.width == ShelfTrees.wingWidth)
    #expect(texts(wing.root) == ["2"])
}

// MARK: - The look of the in-app view

private func node(_ tree: ViewNode, button id: String) -> ViewNode? {
    nodes(tree).first { if case let .button(buttonID, _, _, _, _, _, _, _, _) = $0.kind { buttonID == id } else { false } }
}

private func tilePreview() -> ShelfTrees.Tile {
    ShelfTrees.Tile(id: "stack:1", title: "a.png", preview: ShelfTrees.missingFile, count: 2, hasFiles: true,
                    drag: ViewNode.ItemDrag([.file(path: "/tmp/a.png")]), isStack: true)
}

@Test func headerLinesUpOnTheFirstBaselineWithTooltips() throws {
    let state = ShelfTrees.State(itemCount: 2, isDropTarget: false, isReceiving: true, shownStackCount: 2, tiles: [tilePreview()])
    let root = ShelfTrees.expanded(state)
    // Padding 18 at the sides, 6 at the top, 14 at the bottom, and not moved.
    guard case let .vstack(children, _, _, padding, offset) = root.kind else {
        Issue.record("not a vstack")
        return
    }
    #expect(padding == .init(horizontal: 18, top: 6, bottom: 14))
    #expect(offset == nil)
    let header = try #require(children.first)
    guard case let .hstack(_, spacing, alignment, _, _) = header.kind else {
        Issue.record("header is not an hstack")
        return
    }
    #expect(spacing == 8 && alignment == .firstTextBaseline)
    #expect(node(root, button: "back")?.help == "Back to the shelf")
    #expect(node(root, button: "clear")?.help == "Remove everything from the shelf")
    #expect(nodes(root).first { if case .spinner = $0.kind { true } else { false } }?.help == "Waiting for dropped files")
}

@Test func removeButtonIsSixteenPointBlackOnWhiteAndFollowsTheTileHover() throws {
    let tile = ShelfTrees.tile(tilePreview())
    let item = try #require(items(tile).first)
    let overlay = try #require(item.overlay)
    let remove = try #require(node(overlay, button: "remove:stack:1"))
    #expect(remove.help == "Remove from the shelf")
    guard case let .button(_, title, style, symbol, _, _, restOpacity, _, label) = remove.kind else {
        Issue.record("not a button")
        return
    }
    #expect(title == "Remove from the shelf" && style == .plain && symbol == nil && restOpacity == 0.6)
    #expect(label == .symbol("xmark.circle.fill", size: 16, color: WireColor("#000000"), secondaryColor: WireColor("#FFFFFF")))
    // Top trailing, moved 2 right and 2 up, as the in-app overlay.
    guard case let .frame(child, _, _, fill, alignment) = overlay.kind,
          case let .hstack(_, _, _, _, offset) = child.kind else {
        Issue.record("overlay is not a frame around an hstack")
        return
    }
    #expect(fill == .both && alignment == .topTrailing && offset == .init(x: 2, y: -2))
}

@Test func linkHostIsCentred() {
    let link = ShelfTrees.link(URL(string: "https://example.com/a")!)
    let attributes = nodes(link).compactMap { if case let .styledText(_, attributes) = $0.kind { attributes } else { nil } }
    #expect(attributes.map(\.alignment) == [.center])
}
