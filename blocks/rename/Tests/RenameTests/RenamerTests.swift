import Foundation
import Testing
@testable import RenameCore

/// Whole seconds, so the comparison does not depend on sub-second storage.
private let created = Date(timeIntervalSince1970: 1_700_000_000)
private let modified = Date(timeIntervalSince1970: 1_700_000_500)

private func makeScreenshot(in folder: URL, name: String = "Screenshot 2026-11-18 at 10.00.00.png") throws -> URL {
    let url = try makeFile(name, in: folder)
    try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
    return url
}

@Test func renameMovesTheFileKeepsItsDatesAndStoresTheOriginalName() throws {
    let folder = try makeTempFolder()
    let source = try makeScreenshot(in: folder)
    let before = Renamer.dates(of: source)

    let target = try Renamer().rename(source, to: "payment-failed.png")

    #expect(target.lastPathComponent == "payment-failed.png")
    #expect(exists(target))
    #expect(!exists(source))
    #expect(Renamer.dates(of: target) == before)
    #expect(before == Renamer.Dates(created: created, modified: modified))
    #expect(Renamer.originalName(of: target) == source.lastPathComponent)
}

@Test func renameAvoidsAnExistingName() throws {
    let folder = try makeTempFolder()
    let source = try makeScreenshot(in: folder)
    try makeFile("payment-failed.png", in: folder)

    let target = try Renamer().rename(source, to: "payment-failed.png")

    #expect(target.lastPathComponent == "payment-failed-2.png")
}

@Test func renamingAMissingFileThrows() throws {
    let folder = try makeTempFolder()
    let missing = folder.appending(path: "gone.png")
    #expect(throws: RenameError.fileMissing) {
        try Renamer().rename(missing, to: "x.png")
    }
}

@Test func undoRestoresTheNameAndDatesAndRemovesTheAttribute() throws {
    let folder = try makeTempFolder()
    let source = try makeScreenshot(in: folder)
    let renamer = Renamer()
    let target = try renamer.rename(source, to: "payment-failed.png")

    let restored = try renamer.undo(target, originalName: source.lastPathComponent)

    #expect(restored.lastPathComponent == source.lastPathComponent)
    #expect(exists(source))
    #expect(!exists(target))
    #expect(Renamer.dates(of: restored) == Renamer.Dates(created: created, modified: modified))
    #expect(Renamer.originalName(of: restored) == nil)
}

@Test func undoWhenTheOriginalNameIsTakenLeavesTheFileAlone() throws {
    let folder = try makeTempFolder()
    let source = try makeScreenshot(in: folder)
    let renamer = Renamer()
    let target = try renamer.rename(source, to: "payment-failed.png")
    try makeFile(source.lastPathComponent, in: folder, contents: "other")

    #expect(throws: RenameError.originalNameTaken(source.lastPathComponent)) {
        try renamer.undo(target, originalName: source.lastPathComponent)
    }
    #expect(exists(target))
    #expect(Renamer.originalName(of: target) == source.lastPathComponent)
}

// MARK: Recents

private func recent(_ n: Int) -> RecentRename {
    RecentRename(
        folderPath: "/tmp",
        newName: "name-\(n).png",
        originalName: "Screenshot \(n).png",
        renamedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n) + 0.25),
        usedFallback: n.isMultiple(of: 2)
    )
}

@Test func recentsSurviveARoundTrip() throws {
    let folder = try makeTempFolder()
    let store = RecentsStore(url: folder.appending(path: "Rename/recents.json"))
    var items = [recent(2), recent(1)]
    items[1].reverted = true

    try store.save(items)
    let loaded = store.load()

    #expect(loaded == items)
}

@Test func recentsKeepAtMostTwenty() throws {
    let folder = try makeTempFolder()
    let store = RecentsStore(url: folder.appending(path: "recents.json"))
    try store.save((0..<25).map(recent))
    let loaded = store.load()
    #expect(loaded.count == 20)
    #expect(loaded.first?.newName == "name-0.png")
}

@Test func missingRecentsLoadAsEmpty() throws {
    let folder = try makeTempFolder()
    let store = RecentsStore(url: folder.appending(path: "none.json"))
    #expect(store.load().isEmpty)
}

@Test func undoRefusesAFileThisAppDidNotRename() throws {
    let folder = try makeTempFolder()
    let source = try makeScreenshot(in: folder)
    let renamer = Renamer()
    let target = try renamer.rename(source, to: "payment-failed.png")
    // Another file takes the renamed path.
    try FileManager.default.removeItem(at: target)
    try makeFile("payment-failed.png", in: folder, contents: "newer")

    #expect(throws: RenameError.fileChanged) {
        try renamer.undo(target, originalName: source.lastPathComponent)
    }
    #expect(exists(target))
    #expect(!exists(source))
}
