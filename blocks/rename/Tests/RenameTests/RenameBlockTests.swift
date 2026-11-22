import BlockKit
import BlockKitTesting
import CoreGraphics
import Foundation
import Testing
@testable import RenameCore

// The block's behaviour, ported from the in-app block's tests. Each test runs
// the block over `FakeHost`, as the app would, and asserts on the messages it
// sends in place of the old model.

private let titleLines = [
    RecognizedLine(text: "Payment Failed", box: CGRect(x: 0.1, y: 0.84, width: 0.5, height: 0.06)),
    RecognizedLine(text: "Your card was declined", box: CGRect(x: 0.1, y: 0.77, width: 0.5, height: 0.03)),
    RecognizedLine(text: "Contact support", box: CGRect(x: 0.1, y: 0.17, width: 0.5, height: 0.03)),
]

private let quickReader = FakeReader { _ in titleLines }
private let utc = TimeZone(identifier: "UTC")!

// MARK: - Helpers

/// A running block, welcomed with `settings` and `folder/state` as its data folder.
@MainActor
private func start(
    in folder: URL,
    reader: FakeReader = quickReader,
    namer: FakeNamer = FakeNamer { _ in "payment failed dialog" },
    timeLimit: Duration = .seconds(10),
    appName: String? = nil,
    settings: [String: SettingValue] = [:]
) async throws -> FakeHost {
    let host = FakeHost()
    host.run(RenameBlock(reader: reader, namer: namer, timeLimit: timeLimit, frontmostAppName: { appName }, timeZone: utc))
    try await host.welcome(settings: settings, dataFolder: dataFolder(folder).path)
    try await settle(host)
    return host
}

private func dataFolder(_ folder: URL) -> URL {
    folder.appending(path: "state", directoryHint: .isDirectory)
}

private func storedRecents(_ folder: URL) -> [RecentRename] {
    RecentsStore(dataFolder: dataFolder(folder)).load()
}

private func capture(_ url: URL, on host: FakeHost, at date: Date = Date()) throws {
    try host.event(.screenshotCaptured(.init(path: url.path, createdAt: date.timeIntervalSince1970)), seq: 1)
}

/// Waits until the block has handled every message sent so far: the kit
/// answers a ping on the main queue after every message sent before it.
private func settle(_ host: FakeHost) async throws {
    let seq = host.received.filter(isPong).count + 1
    try host.send(.ping(seq: seq))
    _ = await host.waitFor { $0 == .pong(seq: seq) }
}

private func isPong(_ message: BlockToHost) -> Bool { if case .pong = message { true } else { false } }

private struct Shown {
    let priority: Priority
    let peek: ViewSlot?
    let wing: ViewSlot?
    let expanded: ViewSlot?
    let seconds: Double?
}

private func presents(_ host: FakeHost) -> [Shown] {
    host.received.compactMap {
        if case let .present(priority, peek, wing, expanded, _, seconds, _, _, _) = $0 {
            Shown(priority: priority, peek: peek, wing: wing, expanded: expanded, seconds: seconds)
        } else { nil }
    }
}

private func isPresent(seconds: Double?) -> @Sendable (BlockToHost) -> Bool {
    { message in
        if case let .present(_, _, _, _, _, shown, _, _, _) = message { shown == seconds } else { false }
    }
}

/// Waits for `count` presents that last `seconds`: a result is 6, a failure 4.
private func waitForPresents(_ host: FakeHost, seconds: Double?, count: Int = 1) async -> [BlockToHost] {
    await host.messages(count: count, timeout: .seconds(5), isPresent(seconds: seconds))
}

private func waitForDismiss(_ host: FakeHost) async {
    _ = await host.waitFor(timeout: .seconds(5)) { $0 == .dismiss }
}

private func lastActions(_ host: FakeHost) -> [ActionItem]? {
    host.received.last(where: { if case .actions = $0 { true } else { false } }).flatMap {
        if case let .actions(items) = $0 { items } else { nil }
    }
}

private func updates(_ host: FakeHost) -> [(peek: ViewNode?, expanded: ViewNode?)] {
    host.received.compactMap { if case let .update(peek, _, expanded) = $0 { (peek, expanded) } else { nil } }
}

private func allNodes(_ node: ViewNode?) -> [ViewNode] {
    guard let node else { return [] }
    return [node] + node.children.flatMap { allNodes($0) }
}

/// Every line of text in the tree: plain text, and styled text with its runs joined.
private func texts(_ node: ViewNode?) -> [String] {
    allNodes(node).compactMap {
        switch $0.kind {
        case let .text(text, _): text
        case let .styledText(runs, _): runs.map(\.text).joined()
        default: nil
        }
    }
}

private func buttonIDs(_ node: ViewNode?) -> [String] {
    allNodes(node).compactMap { if case let .button(id, _, _, _, _, _, _, _, _) = $0.kind { id } else { nil } }
}

private func hasSweep(_ node: ViewNode?) -> Bool {
    allNodes(node).contains { if case .sweep = $0.kind { true } else { false } }
}

private func drainingBars(_ node: ViewNode?) -> [Double] {
    allNodes(node).compactMap { if case let .progress(_, _, _, drainsOver, _) = $0.kind { drainsOver } else { nil } }
}

// MARK: - Ported from the in-app block

@Test func aCaptureShowsNamingInThePeekUntilDismissed() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)

    try capture(shot, on: host)
    let naming = try #require(await waitForPresents(host, seconds: nil).first)

    guard case let .present(priority, peek, wing, _, _, _, _, _, _) = naming else { return }
    #expect(priority == .standard)
    // A full peek that says which screenshot, not a mark beside the notch.
    #expect(wing == nil)
    #expect(peek != nil)
    #expect(peek?.width == 420)
    #expect(peek?.height == 54)
    #expect(texts(peek.map(\.root)).contains("Reading the screenshot\u{2026}"))
    #expect(texts(peek.map(\.root)).contains("Screenshot 1"))
    _ = await waitForPresents(host, seconds: 6)
}

@Test func namesReadAsWordsInTheNotchAndKeepTheirFileNames() {
    #expect(RenameDisplay.words("shelf-rename-panel-ears.png") == "Shelf Rename Panel Ears")
    #expect(RenameDisplay.words("2026-11-19-login_page.png") == "2026 11 19 Login Page")
    // One word, or a name macOS gave: shown as it is, without the extension.
    #expect(RenameDisplay.words("invoice.pdf") == "invoice")
    #expect(RenameDisplay.words("Screenshot 2026-11-19 at 6.45.56 PM.png") == "Screenshot 2026-11-19 at 6.45.56 PM")
    #expect(RenameDisplay.original("Screenshot 2026-11-19 at 6.45.56 PM.png") == "Screenshot 2026-11-19 at 6.45.56 PM")
}

@Test func aNamedScreenshotIsRenamedAndShownWithADuration() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)

    try capture(shot, on: host)
    let result = try #require(await waitForPresents(host, seconds: 6).first)

    let renamed = folder.appending(path: "payment-failed-dialog.png")
    #expect(exists(renamed))
    #expect(!exists(shot))
    let recents = storedRecents(folder)
    #expect(recents.map(\.newName) == ["payment-failed-dialog.png"])
    #expect(recents.first?.usedFallback == false)
    #expect(recents.first?.originalName == "Screenshot 1.png")
    #expect(exists(dataFolder(folder).appending(path: "recents.json")))
    guard case let .present(_, peek, _, expanded, _, _, _, _, _) = result else { return }
    #expect(texts(peek.map(\.root)).contains("Payment Failed Dialog"))
    #expect(texts(peek.map(\.root)).contains("was Screenshot 1"))
    #expect(texts(expanded.map(\.root)).contains("Payment Failed Dialog"))
}

@Test func undoInThePeekRestoresTheNameAndDismisses() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)
    try capture(shot, on: host)
    _ = await waitForPresents(host, seconds: 6)

    try host.send(.input(input: .button(id: RenameTrees.undoID)))
    try await settle(host)

    #expect(exists(shot))
    #expect(!exists(folder.appending(path: "payment-failed-dialog.png")))
    #expect(host.received.last(where: { !isPong($0) && !isActions($0) }) == .dismiss)
    #expect(storedRecents(folder).first?.reverted == true)

    // The watcher may report the restored file; it must not be renamed again.
    let before = presents(host).count
    try capture(shot, on: host)
    try await settle(host)
    #expect(presents(host).count == before)
    #expect(exists(shot))
}

private func isActions(_ message: BlockToHost) -> Bool { if case .actions = message { true } else { false } }

@Test func aModelTimeOutUsesTheFallbackName() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let slowNamer = FakeNamer { _ in
        try await Task.sleep(for: .seconds(10))
        return "too late"
    }
    let host = try await start(in: folder, namer: slowNamer, timeLimit: .milliseconds(50))

    try capture(shot, on: host)
    #expect(await waitForPresents(host, seconds: 6).count == 1)

    #expect(exists(folder.appending(path: "screenshot-payment-failed.png")))
    #expect(storedRecents(folder).first?.usedFallback == true)
}

@Test func anUnavailableModelUsesTheFallbackName() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let unavailable = FakeNamer(status: .appleIntelligenceNotEnabled) { _ in
        Issue.record("the namer must not be asked when the model is unavailable")
        return "never"
    }
    let host = try await start(in: folder, namer: unavailable)

    try capture(shot, on: host)
    _ = await waitForPresents(host, seconds: 6)

    #expect(exists(folder.appending(path: "screenshot-payment-failed.png")))
    #expect(host.notes.last == SettingNote(key: "modelStatus", text: ModelStatus.appleIntelligenceNotEnabled.explanation))
}

@Test func aFileDeletedMidwayIsDroppedAndTheNotchReturnsToIdle() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let deletingReader = FakeReader { url in
        try FileManager.default.removeItem(at: url)
        return titleLines
    }
    let host = try await start(in: folder, reader: deletingReader)

    try capture(shot, on: host)
    #expect(await waitForPresents(host, seconds: nil).count == 1)
    await waitForDismiss(host)

    #expect(host.received.contains(.dismiss))
    #expect(presents(host).count == 1)
    #expect(storedRecents(folder).isEmpty)
}

@Test func twoCapturesAreProcessedInOrder() async throws {
    let folder = try makeTempFolder()
    let first = try makeFile("alpha.png", in: folder)
    let second = try makeFile("beta.png", in: folder)
    let order = Recorder<String>()
    let reader = FakeReader { url in
        order.add(url.lastPathComponent)
        // Long enough for the second capture to arrive while the first is named.
        if url.lastPathComponent == "alpha.png" { try await Task.sleep(for: .milliseconds(300)) }
        let word = url.deletingPathExtension().lastPathComponent
        return [RecognizedLine(text: word, box: CGRect(x: 0, y: 0.8, width: 0.5, height: 0.1))]
    }
    let namer = FakeNamer { request in "\(request.lines.first ?? "") renamed" }
    let host = try await start(in: folder, reader: reader, namer: namer)

    try capture(first, on: host)
    try capture(second, on: host)
    try await settle(host)
    // The one waiting is shown in the peek.
    #expect(updates(host).contains { texts($0.peek).contains("+1 next") })

    #expect(await waitForPresents(host, seconds: 6).count == 1)
    // One result, for the last one: the first result is not shown.
    #expect(presents(host).filter { $0.seconds == 6 }.count == 1)

    #expect(order.values == ["alpha.png", "beta.png"])
    #expect(exists(folder.appending(path: "alpha-renamed.png")))
    #expect(exists(folder.appending(path: "beta-renamed.png")))
    #expect(storedRecents(folder).map(\.newName) == ["beta-renamed.png", "alpha-renamed.png"])
    let last = try #require(presents(host).last)
    #expect(!texts(last.peek.map(\.root)).contains { $0.hasSuffix("next") })
}

@Test func theSameCaptureTwiceIsNamedOnce() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)

    try capture(shot, on: host)
    try capture(shot, on: host)
    try await settle(host)
    #expect(!updates(host).contains { texts($0.peek).contains("+1 next") })
    _ = await waitForPresents(host, seconds: 6)

    #expect(storedRecents(folder).count == 1)
    #expect(presents(host).filter { $0.seconds == nil }.count == 1)
}

@Test func undoLastRenameIsOfferedOnceSomethingWasRenamed() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)
    #expect(lastActions(host)?.first?.enabled == false)

    try capture(shot, on: host)
    _ = await waitForPresents(host, seconds: 6)
    try await settle(host)
    let action = try #require(lastActions(host)?.first)
    #expect(action.id == RenameBlock.undoLastActionID)
    #expect(action.title == "Undo Last Rename")
    #expect(action.enabled)

    try host.send(.action(id: action.id))
    try await settle(host)

    #expect(exists(shot))
    #expect(lastActions(host)?.first?.enabled == false)
}

// MARK: Model prompt

private func line(_ text: String, y: CGFloat, height: CGFloat) -> RecognizedLine {
    RecognizedLine(text: text, box: CGRect(x: 0.1, y: y, width: 0.5, height: height))
}

@Test func theBiggestTextComesFirstWithoutRepeatsOrScraps() {
    let lines = [
        line("File  Edit  View", y: 0.97, height: 0.015),
        line("Payment failed", y: 0.80, height: 0.06),
        line("Your card was declined", y: 0.70, height: 0.03),
        line("OK", y: 0.60, height: 0.05),
        line("payment failed", y: 0.20, height: 0.02),
    ]
    let prominent = RecognizedLine.mostProminent(lines, count: 3)
    #expect(prominent == ["Payment failed", "Your card was declined", "File  Edit  View"])
}

@Test func thePromptLeadsWithTheBiggestTextThenAllOfIt() {
    let prompt = ModelNamer.prompt(text: "line one\nline two", prominent: ["Payment failed"], appName: "Safari")
    let big = try? #require(prompt.range(of: "- Payment failed"))
    let all = try? #require(prompt.range(of: "line one"))
    #expect(prompt.hasPrefix("The screenshot was taken while Safari"))
    if let big, let all { #expect(big.lowerBound < all.lowerBound) }
    // Nothing big on screen: no empty heading.
    let plain = ModelNamer.prompt(text: "x", prominent: [], appName: nil)
    #expect(!plain.contains("biggest text"))
}

@Test func theInstructionsNameTheSubjectAndWhatToIgnore() {
    let instructions = ModelNamer.instructions(for: .matchContent)
    #expect(instructions.contains("subject first"))
    #expect(instructions.contains("Ignore menus"))
    #expect(instructions.contains("Examples of good names"))
}

@Test func theTextSentIsCappedAtWholeLines() {
    let lines = Array(repeating: String(repeating: "a", count: 99), count: 30)
    let text = ModelNamer.truncated(lines, limit: ModelNamer.textLimit)
    #expect(text.count <= ModelNamer.textLimit)
    #expect(ModelNamer.textLimit == 1000)
}

@Test func theModelsAnswerIsCleanedIntoWords() {
    #expect(ModelNamer.words(in: "\"Threads.com Homepage\"\nThis name says…", max: 6) == ["threads.com", "homepage"])
    // Repeats are dropped, and the count is capped.
    #expect(ModelNamer.words(in: "students poll polling polling polling", max: 6) == ["students", "poll", "polling"])
    #expect(ModelNamer.words(in: "one two three four five six seven", max: 4) == ["one", "two", "three", "four"])
    #expect(ModelNamer.words(in: "  ", max: 4).isEmpty)
}

// MARK: - New with the package

@Test func peekTreeForEachPhase() throws {
    let item = RecentRename(
        folderPath: "/tmp", newName: "payment-failed-dialog.png", originalName: "Screenshot 1.png",
        renamedAt: Date(), usedFallback: false
    )

    var state = RenameState()
    state.phase = .naming
    state.currentName = "Screenshot 1.png"
    state.waiting = 2
    let naming = RenameTrees.peek(state)
    #expect(texts(naming) == ["Reading the screenshot\u{2026}", "Screenshot 1", "+2 next"])
    #expect(hasSweep(naming))
    #expect(drainingBars(naming).isEmpty)
    #expect(buttonIDs(naming).isEmpty)
    let next = allNodes(naming).first { if case .capsule = $0.kind { true } else { false } }
    #expect(next != nil)

    state.phase = .renamed(item)
    state.waiting = 0
    let renamed = RenameTrees.peek(state)
    #expect(texts(renamed) == ["Payment Failed Dialog", "was Screenshot 1"])
    let subtitle = try #require(allNodes(renamed).compactMap { node -> [ViewNode.TextRun]? in
        if case let .styledText(runs, _) = node.kind, runs.count == 2 { runs } else { nil }
    }.first)
    #expect(subtitle.map(\.text) == ["was ", "Screenshot 1"])
    #expect(subtitle.map { $0.strikethrough ?? false } == [false, true])
    #expect(buttonIDs(renamed) == [RenameTrees.undoID])
    #expect(!hasSweep(renamed))
    #expect(drainingBars(renamed) == [6])
    let undo = try #require(allNodes(renamed).first { if case .button = $0.kind { true } else { false } })
    guard case let .button(_, title, style, symbol, _, color, _, labelColor, _) = undo.kind else { return }
    #expect(title == "Undo")
    #expect(style == .accent)
    #expect(symbol == "arrow.uturn.backward")
    #expect(color == WireColor("#F5A623"))
    #expect(labelColor == WireColor("#2B1700"))

    state.phase = .failed("The file is gone")
    let failed = RenameTrees.peek(state)
    #expect(texts(failed) == ["Kept the original name", "The file is gone"])
    #expect(!hasSweep(failed))
    #expect(drainingBars(failed).isEmpty)
    #expect(allNodes(failed).contains { if case let .symbol(name, _, _, _, _, _, _) = $0.kind { name == "exclamationmark.triangle" } else { false } })
}

@Test func undoButtonRevertsAndDismisses() async throws {
    let folder = try makeTempFolder()
    let shot = try makeFile("Screenshot 1.png", in: folder)
    let host = try await start(in: folder)
    try capture(shot, on: host)
    let result = try #require(await waitForPresents(host, seconds: 6).first)
    guard case let .present(_, peek, _, _, _, _, _, _, _) = result else { return }
    let undo = try #require(buttonIDs(peek.map(\.root)).first)

    try host.send(.input(input: .button(id: undo)))
    try await settle(host)

    #expect(exists(shot))
    #expect(!exists(folder.appending(path: "payment-failed-dialog.png")))
    #expect(host.received.contains(.dismiss))
}

@Test func revertButtonInRecentsMarksTheRowReverted() async throws {
    let folder = try makeTempFolder()
    let first = try makeFile("Screenshot 1.png", in: folder)
    let second = try makeFile("Screenshot 2.png", in: folder)
    let namer = FakeNamer { _ in "payment failed dialog" }
    let host = try await start(in: folder, namer: namer)
    try capture(first, on: host)
    _ = await waitForPresents(host, seconds: 6)
    try capture(second, on: host)
    let results = await waitForPresents(host, seconds: 6, count: 2)
    guard results.count == 2, case let .present(_, _, _, expanded, _, _, _, _, _) = results[1] else {
        Issue.record("expected two results")
        return
    }
    // Newest first: the second screenshot's row, then the first's.
    let reverts = buttonIDs(expanded?.root)
    #expect(reverts.count == 2)
    let older = try #require(reverts.last)
    #expect(older.hasPrefix(RenameTrees.revertPrefix))

    try host.send(.input(input: .button(id: older)))
    try await settle(host)

    #expect(exists(first))
    #expect(exists(folder.appending(path: "payment-failed-dialog-2.png")))
    let list = try #require(updates(host).last?.expanded)
    #expect(texts(list).contains("Reverted"))
    #expect(buttonIDs(list).count == 1)
    // The result on screen is another file's; it stays.
    #expect(!host.received.contains(.dismiss))
}

@Test func settingsComeFromWelcomeAndFollowSettingMessages() async throws {
    let folder = try makeTempFolder()
    let first = try makeFile("Screenshot 1.png", in: folder)
    let second = try makeFile("Screenshot 2.png", in: folder)
    let requests = Recorder<NamingRequest>()
    let namer = FakeNamer { request in
        requests.add(request)
        return "payment failed dialog"
    }
    let host = try await start(in: folder, namer: namer, appName: "Safari", settings: [
        "nameLength": .string("short"),
        "nameLanguage": .string("english"),
        "datePrefix": .bool(true),
        "appNameSuffix": .bool(true),
    ])
    let date = Date(timeIntervalSince1970: 1_794_996_000)

    try capture(first, on: host, at: date)
    _ = await waitForPresents(host, seconds: 6)

    let welcomed = NamingOptions(length: .short, language: .english, datePrefix: true, appNameSuffix: true)
    #expect(requests.values.first?.length == .short)
    #expect(requests.values.first?.language == .english)
    #expect(requests.values.first?.appName == "Safari")
    let expected = NameCleaner.fileName(
        base: "payment failed dialog", options: welcomed, appName: "Safari", date: date, timeZone: utc, fileExtension: "png"
    )
    #expect(exists(folder.appending(path: expected)))

    try host.send(.setting(key: "nameLength", value: .string("long")))
    try host.send(.setting(key: "appNameSuffix", value: .bool(false)))
    try capture(second, on: host, at: date)
    _ = await waitForPresents(host, seconds: 6, count: 2)

    #expect(requests.values.count == 2)
    #expect(requests.values.last?.length == .long)
    #expect(requests.values.last?.appName == nil)
    #expect(RenameSettings.options(from: [:]) == NamingOptions())
}

@Test func modelStatusIsSentAsASettingNote() async throws {
    let folder = try makeTempFolder()
    let host = try await start(in: folder, namer: FakeNamer(status: .modelNotReady) { _ in "x" })

    // Sent once, after `welcome`: the note in the manifest is only a placeholder.
    #expect(host.notes == [SettingNote(key: "modelStatus", text: ModelStatus.modelNotReady.explanation)])
}

// MARK: - The look of the in-app view

@Test func recentsHeaderLinesUpOnTheFirstBaselineInsideTheInAppPadding() throws {
    let item = RecentRename(
        folderPath: "/tmp", newName: "payment-failed-dialog.png", originalName: "Screenshot 1.png",
        renamedAt: Date(), usedFallback: false
    )
    var state = RenameState()
    state.phase = .naming
    state.recents = [item]
    let tree = RenameTrees.recents(state, fileExists: { _ in false })

    // 18 at the sides and bottom, 6 at the top, on the stack of content.
    guard case let .frame(content, _, _, fill, alignment) = tree.kind,
          case let .vstack(children, spacing, _, padding, _) = content.kind else {
        Issue.record("not a frame around a vstack")
        return
    }
    #expect(fill == .both && alignment == .topLeading)
    #expect(spacing == 12)
    #expect(padding == .init(horizontal: 18, top: 6, bottom: 18))

    let header = try #require(children.first?.children.first)
    guard case let .hstack(_, _, headerAlignment, _, _) = header.kind else {
        Issue.record("header is not an hstack")
        return
    }
    #expect(headerAlignment == .firstTextBaseline)

    // A file that is gone: Revert is disabled, which the app draws at 0.4.
    let revert = try #require(allNodes(tree).first { if case .button = $0.kind { true } else { false } })
    guard case let .button(_, _, _, _, enabled, _, _, _, _) = revert.kind else { return }
    #expect(enabled == false)
}
