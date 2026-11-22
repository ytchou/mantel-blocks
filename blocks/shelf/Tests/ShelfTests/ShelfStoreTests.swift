import Foundation
import Testing
@testable import ShelfCore

/// A fresh, empty directory under the temporary folder.
func makeTemporaryDirectory(_ label: String = "ShelfBlockTests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeFile(named name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data("x".utf8).write(to: url)
    return url
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

let exampleLink = URL(string: "https://example.com/page")!

/// The app gives each block process its own TMPDIR and moves dropped files
/// into `<TMPDIR>/Mantel/Drops` there. Foundation's temporary folder does
/// not follow TMPDIR, so the drop folder is read from the variable.
@Test func theDropFolderIsUnderTheProcessTMPDIR() {
    let root = ShelfStore.dropFolder(environment: ["TMPDIR": "/private/tmp/app/Mantel/Blocks/shelf/"])
    #expect(root.path(percentEncoded: false) == "/private/tmp/app/Mantel/Blocks/shelf/Mantel/Drops/")
}

@Test func withoutTMPDIRTheDropFolderIsUnderTheTemporaryFolder() {
    let fallback = FileManager.default.temporaryDirectory.appending(path: "Mantel/Drops", directoryHint: .isDirectory)
    #expect(ShelfStore.dropFolder(environment: [:]) == fallback)
    #expect(ShelfStore.dropFolder(environment: ["TMPDIR": ""]) == fallback)
}

@MainActor
@Test func oneDropBecomesOneStack() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    let stack = store.add([.text("hello"), .link(exampleLink)])
    #expect(stack?.items.count == 2)
    #expect(store.stacks.count == 1)
    #expect(store.itemCount == 2)
}

@MainActor
@Test func newerDropsComeFirst() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    let first = store.add([.text("one")])
    let second = store.add([.text("two")])
    #expect(store.stacks.map(\.id) == [second?.id, first?.id].compactMap { $0 })
}

@MainActor
@Test func aDropWithNothingUsableAddsNothing() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    let stack = store.add([.text("")])
    #expect(stack == nil)
    #expect(store.isEmpty)
}

@MainActor
@Test func removingAnItemKeepsTheRestOfItsStack() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    let stack = try #require(store.add([.text("Ship the release notes by Friday"), .text("Dear Ana,\nThanks for the review.\nSee you Monday.")]))
    let firstItem = try #require(stack.items.first)

    store.remove(.item(firstItem.id))
    #expect(store.stacks.count == 1)
    #expect(store.itemCount == 1)

    let lastItem = try #require(store.stacks.first?.items.first)
    store.remove(.item(lastItem.id))
    #expect(store.isEmpty)
}

@MainActor
@Test func removingAStackRemovesAllItsItems() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    let kept = try #require(store.add([.text("keep")]))
    let removed = try #require(store.add([.text("Ship the release notes by Friday"), .text("Dear Ana,\nThanks for the review.\nSee you Monday.")]))

    store.remove(.stack(removed.id))
    #expect(store.stacks.map(\.id) == [kept.id])
}

@MainActor
@Test func clearRemovesEverything() throws {
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    store.add([.text("Ship the release notes by Friday")])
    store.add([.link(exampleLink)])
    store.clear()
    #expect(store.isEmpty)
    #expect(store.itemCount == 0)
}

@MainActor
@Test func itemsSurviveARelaunch() throws {
    let directory = try makeTemporaryDirectory()
    let userFile = try makeFile(named: "report.pdf", in: try makeTemporaryDirectory("ShelfUserFiles"))
    let store = ShelfStore(directory: directory)
    store.add([.file(userFile), .text("snippet")])
    store.add([.link(exampleLink)])

    let reloaded = ShelfStore(directory: directory)
    #expect(reloaded.stacks == store.stacks)
    #expect(reloaded.itemCount == 3)
    let fileItem = try #require(reloaded.stacks.last?.items.first)
    #expect(reloaded.fileURL(of: fileItem)?.lastPathComponent == "report.pdf")
}

@MainActor
@Test func itemsWhoseFileIsGoneAreDropped() throws {
    let directory = try makeTemporaryDirectory()
    let userFiles = try makeTemporaryDirectory("ShelfUserFiles")
    let gone = try makeFile(named: "gone.txt", in: userFiles)
    let kept = try makeFile(named: "kept.txt", in: userFiles)
    let store = ShelfStore(directory: directory)
    store.add([.file(gone), .file(kept)])
    store.add([.file(gone)])

    try FileManager.default.removeItem(at: gone)

    let reloaded = ShelfStore(directory: directory)
    #expect(reloaded.stacks.count == 1)
    #expect(reloaded.itemCount == 1)

    store.pruneMissing()
    #expect(store.itemCount == 1)
}

@MainActor
@Test func aPromisedFileIsMovedIntoTheShelfsStorage() throws {
    let directory = try makeTemporaryDirectory()
    let dropFolder = try makeTemporaryDirectory("ShelfShell")
        .appending(path: "Mantel/Drops/\(UUID().uuidString)", directoryHint: .isDirectory)
    let promised = try makeFile(named: "photo.png", in: dropFolder)
    let store = ShelfStore(directory: directory)
    store.dropRoot = dropFolder.deletingLastPathComponent()

    let stack = try #require(store.add([.file(promised)]))
    let item = try #require(stack.items.first)
    let stored = try #require(store.fileURL(of: item))

    #expect(!exists(promised))
    #expect(exists(stored))
    #expect(stored.lastPathComponent == "photo.png")
    #expect(stored.path(percentEncoded: false).hasPrefix(store.filesDirectory.path(percentEncoded: false)))
    #expect(item.isOwnedFile)

    store.remove(.stack(stack.id))
    #expect(!exists(stored))
}

@MainActor
@Test func removingAUsersFileNeverDeletesIt() throws {
    let userFile = try makeFile(named: "mine.txt", in: try makeTemporaryDirectory("ShelfUserFiles"))
    let store = ShelfStore(directory: try makeTemporaryDirectory())
    store.add([.file(userFile)])
    store.add([.file(userFile)])

    let first = try #require(store.stacks.first)
    store.remove(.stack(first.id))
    store.clear()
    #expect(exists(userFile))
}

@MainActor
@Test func ownedFilesKeptByADragOutAreSweptAtTheNextLaunch() throws {
    let directory = try makeTemporaryDirectory()
    let dropFolder = try makeTemporaryDirectory("ShelfShell")
        .appending(path: "Mantel/Drops/\(UUID().uuidString)", directoryHint: .isDirectory)
    let promised = try makeFile(named: "clip.mov", in: dropFolder)
    let store = ShelfStore(directory: directory)
    store.dropRoot = dropFolder.deletingLastPathComponent()
    let stack = try #require(store.add([.file(promised)]))
    let stored = try #require(stack.items.first.flatMap { store.fileURL(of: $0) })

    store.remove(.stack(stack.id), deleteOwnedFiles: false)
    #expect(exists(stored))

    _ = ShelfStore(directory: directory)
    #expect(!exists(stored))
}

@MainActor
@Test func aUsersFolderNamedLikeTheDropFolderIsNotMoved() throws {
    let directory = try makeTemporaryDirectory()
    let lookalike = try makeTemporaryDirectory("ShelfUser")
        .appending(path: "Mantel/Drops/mine", directoryHint: .isDirectory)
    let file = try makeFile(named: "keep.png", in: lookalike)
    let store = ShelfStore(directory: directory)

    let stack = try #require(store.add([.file(file)]))
    store.remove(.stack(stack.id), deleteOwnedFiles: true)

    #expect(exists(file))
}

// MARK: - Moved from the in-app shelf

/// `<root>/Mantel/BlockData/shelf`, the data folder, and `<root>/Mantel/Shelf`,
/// where the in-app shelf kept its data before the app moved it.
private func movedLayout() throws -> (data: URL, old: URL) {
    let mantel = try makeTemporaryDirectory("ShelfMove").appending(path: "Mantel", directoryHint: .isDirectory)
    let data = mantel.appending(path: "BlockData/shelf", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    return (data, mantel.appending(path: "Shelf", directoryHint: .isDirectory))
}

private func writeIndex(_ stacks: [ShelfStack], in directory: URL) throws {
    try JSONEncoder().encode(stacks).write(to: directory.appending(path: "index.json"))
}

@MainActor
@Test func ownedFilesOfTheInAppShelfAreKeptAfterTheFolderMoved() throws {
    let (data, old) = try movedLayout()
    let uuid = UUID().uuidString
    // On disk where the app moved them; the index still names the old folder.
    let moved = try makeFile(named: "Meeting notes.pdf", in: data.appending(path: "Files/\(uuid)", directoryHint: .isDirectory))
    let oldPath = old.appending(path: "Files/\(uuid)/Meeting notes.pdf").path(percentEncoded: false)
    let userFile = try makeFile(named: "Quarterly report.key", in: try makeTemporaryDirectory("ShelfUserFiles"))
    let userPath = userFile.path(percentEncoded: false)
    try writeIndex([ShelfStack(items: [
        ShelfItem(content: .file(path: oldPath, bookmark: nil, isOwned: true)),
        ShelfItem(content: .file(path: userPath, bookmark: nil, isOwned: false)),
    ])], in: data)

    let store = ShelfStore(directory: data)

    #expect(store.itemCount == 2)
    #expect(exists(moved))
    let items = try #require(store.stacks.first?.items)
    let owned = try #require(items.first)
    #expect(store.fileURL(of: owned)?.standardizedFileURL == moved.standardizedFileURL)
    guard case let .file(ownedPath, _, true) = owned.content else { Issue.record("not an owned file"); return }
    #expect(!ownedPath.hasPrefix(old.path(percentEncoded: false)))
    guard case let .file(keptPath, _, false) = items.last?.content else { Issue.record("not a user file"); return }
    #expect(keptPath == userPath)

    // Saved: a relaunch finds the new paths and still keeps the file.
    let reloaded = ShelfStore(directory: data)
    #expect(reloaded.stacks == store.stacks)
    #expect(exists(moved))
}

@MainActor
@Test func theOldFolderIsMatchedThroughSymlinks() throws {
    let (data, old) = try movedLayout()
    let uuid = UUID().uuidString
    let moved = try makeFile(named: "Screen Recording.mov", in: data.appending(path: "Files/\(uuid)", directoryHint: .isDirectory))
    let resolvedOld = old.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: "Shelf")
    let oldPath = resolvedOld.appending(path: "Files/\(uuid)/Screen Recording.mov").path(percentEncoded: false)
    try writeIndex([ShelfStack(items: [ShelfItem(content: .file(path: oldPath, bookmark: nil, isOwned: true))])], in: data)

    let store = ShelfStore(directory: data)

    #expect(store.itemCount == 1)
    #expect(exists(moved))
}
