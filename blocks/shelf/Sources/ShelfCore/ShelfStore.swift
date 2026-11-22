import Foundation
import os

/// The shelf's items and their persistence.
///
/// `directory` is the block's data folder from `welcome`. Layout:
/// - `index.json`: the stacks, newest first.
/// - `Files/<uuid>/<name>`: promised files moved out of the shell's temporary
///   drop folder. These are the only files the shelf ever deletes.
///
/// Every change is saved at once; the index is small.
@MainActor
final class ShelfStore {
    /// Newest first.
    private(set) var stacks: [ShelfStack] = []

    let directory: URL
    private let log = Logger(subsystem: "dev.mantel.Mantel", category: "shelf")

    /// Where the app puts dropped files from a promise, in this block's own
    /// temporary folder. That folder is emptied at the next launch, so such
    /// files are moved into storage. The shelf must not import the shell.
    static let defaultDropRoot = dropFolder(environment: ProcessInfo.processInfo.environment)

    /// `<TMPDIR>/Mantel/Drops`. The app starts each block with its own
    /// TMPDIR and moves dropped files there before sending the drop.
    /// Foundation's temporary folder ignores TMPDIR, so the variable is read
    /// here; without it (or empty), the temporary folder is used.
    nonisolated static func dropFolder(environment: [String: String]) -> URL {
        let temporary = environment["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
        return temporary.appending(path: "Mantel/Drops", directoryHint: .isDirectory)
    }

    /// Tests point this at their own folder.
    var dropRoot = ShelfStore.defaultDropRoot

    /// True only for a file inside `dropRoot`. A prefix test on resolved
    /// paths, so a user folder that merely has a similar name is never moved.
    func isInDropFolder(_ url: URL) -> Bool {
        let root = dropRoot.resolvingSymlinksInPath().path(percentEncoded: false)
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    var filesDirectory: URL { directory.appending(path: "Files", directoryHint: .isDirectory) }
    private var indexURL: URL { directory.appending(path: "index.json", directoryHint: .notDirectory) }

    init(directory: URL) {
        self.directory = directory
        load()
        pruneMissing()
        sweepUnreferencedFiles()
    }

    var itemCount: Int { stacks.reduce(0) { $0 + $1.items.count } }
    var isEmpty: Bool { stacks.isEmpty }

    func stack(_ id: UUID) -> ShelfStack? { stacks.first { $0.id == id } }

    /// The items a target covers, in order. Empty when it no longer exists.
    func items(for target: ShelfTarget) -> [ShelfItem] {
        switch target {
        case let .stack(id):
            return stack(id)?.items ?? []
        case let .item(id):
            for stack in stacks {
                if let item = stack.items.first(where: { $0.id == id }) { return [item] }
            }
            return []
        }
    }

    // MARK: Changes

    /// Add one drop as one stack. Returns nil when nothing could be added.
    @discardableResult
    func add(_ dropped: [DroppedItem]) -> ShelfStack? {
        let items = dropped.compactMap { makeItem($0) }
        guard !items.isEmpty else { return nil }
        let stack = ShelfStack(items: items)
        stacks.insert(stack, at: 0)
        save()
        log.info("added stack items=\(items.count)")
        return stack
    }

    /// Remove a stack or one item. A stack left empty is removed too.
    ///
    /// `deleteOwnedFiles: false` keeps the shelf's own copies of promised
    /// files on disk; the sweep at next launch deletes them. A drag-out uses
    /// it, because the receiving app may still be reading the file.
    func remove(_ target: ShelfTarget, deleteOwnedFiles: Bool = true) {
        let removed = items(for: target)
        guard !removed.isEmpty else { return }
        switch target {
        case let .stack(id):
            stacks.removeAll { $0.id == id }
        case let .item(id):
            for index in stacks.indices {
                stacks[index].items.removeAll { $0.id == id }
            }
            stacks.removeAll { $0.items.isEmpty }
        }
        if deleteOwnedFiles { removed.forEach { deleteOwnedFile($0) } }
        save()
        log.info("removed items=\(removed.count)")
    }

    func clear() {
        guard !stacks.isEmpty else { return }
        let removed = stacks.flatMap(\.items)
        stacks = []
        removed.forEach { deleteOwnedFile($0) }
        save()
        log.info("cleared items=\(removed.count)")
    }

    /// Drop items whose file no longer exists (deleted, moved to the Trash,
    /// or on a volume no longer mounted).
    func pruneMissing() {
        var changed = false
        for index in stacks.indices {
            let before = stacks[index].items.count
            stacks[index].items.removeAll { item in
                guard item.isFile else { return false }
                return fileURL(of: item) == nil
            }
            changed = changed || stacks[index].items.count != before
        }
        let beforeStacks = stacks.count
        stacks.removeAll { $0.items.isEmpty }
        if changed || stacks.count != beforeStacks {
            save()
            log.info("pruned missing files")
        }
    }

    // MARK: Files

    /// Where a file item is now, or nil when the file is gone. A bookmark
    /// made by the app may not resolve in the block's process; the stored
    /// path is then the answer.
    func fileURL(of item: ShelfItem) -> URL? {
        guard case let .file(path, bookmark, _) = item.content else { return nil }
        var candidates: [URL] = []
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                candidates.append(url)
            }
        }
        candidates.append(URL(filePath: path))
        return candidates.first { url in
            // A file the user trashed counts as removed, though it still exists.
            !url.path(percentEncoded: false).contains("/.Trash/")
                && FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    private func makeItem(_ dropped: DroppedItem) -> ShelfItem? {
        switch dropped {
        case let .link(url):
            return ShelfItem(content: .link(url))
        case let .text(text):
            return text.isEmpty ? nil : ShelfItem(content: .text(text))
        case let .file(url):
            if isInDropFolder(url) {
                guard let moved = moveIntoStorage(url) else { return nil }
                return ShelfItem(content: .file(path: moved.path(percentEncoded: false), bookmark: nil, isOwned: true))
            }
            // Not security-scoped: the block's sandbox is a profile, not App Sandbox.
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return ShelfItem(content: .file(path: url.path(percentEncoded: false), bookmark: bookmark, isOwned: false))
        }
    }

    /// Move a promised file into `Files/<uuid>/`, keeping its name.
    private func moveIntoStorage(_ url: URL) -> URL? {
        let folder = filesDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(path: url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            log.error("could not move promised file into storage: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Delete the storage folder of an owned file. Anything outside
    /// `Files/` is never touched, whatever the index says.
    private func deleteOwnedFile(_ item: ShelfItem) {
        guard case let .file(path, _, isOwned) = item.content, isOwned,
              let folder = ownedFolder(ofPath: path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            log.error("could not delete shelf file: \(error.localizedDescription)")
        }
    }

    /// `Files/<uuid>` for a path inside it, or nil for any other path.
    private func ownedFolder(ofPath path: String) -> URL? {
        let root = filesDirectory.standardizedFileURL.pathComponents
        let components = URL(filePath: path).standardizedFileURL.pathComponents
        guard components.count > root.count + 1, Array(components.prefix(root.count)) == root else { return nil }
        return filesDirectory.appending(path: components[root.count], directoryHint: .isDirectory)
    }

    /// Delete storage folders no item refers to: left by drag-outs, or by a
    /// crash between moving a file and saving the index.
    private func sweepUnreferencedFiles() {
        let referenced = Set(stacks.flatMap(\.items).compactMap { item -> String? in
            guard case let .file(path, _, true) = item.content else { return nil }
            return ownedFolder(ofPath: path)?.lastPathComponent
        })
        let folders = (try? FileManager.default.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !referenced.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            stacks = try JSONDecoder().decode([ShelfStack].self, from: data)
        } catch {
            log.error("could not read shelf index: \(error.localizedDescription)")
        }
        if rewriteOldFolderPaths() {
            save()
            log.info("moved shelf paths to the data folder")
        }
    }

    /// The in-app shelf kept its data in `Mantel/Shelf`. The app moves that
    /// folder to this data folder (`Mantel/BlockData/shelf`), but the index
    /// still names owned files by their old absolute paths. Rewrite those
    /// before pruning, or the files would be pruned and swept. Bookmarks are
    /// left alone: owned files have none, and a user's file never lived there.
    private func rewriteOldFolderPaths() -> Bool {
        let mantel = directory.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let oldFolders = [
            mantel.appending(path: "Shelf", directoryHint: .isDirectory),
            mantel.resolvingSymlinksInPath().appending(path: "Shelf", directoryHint: .isDirectory),
        ].map { Self.folderPrefix($0) }
        let newFolder = Self.folderPrefix(directory.standardizedFileURL)
        var changed = false
        for stackIndex in stacks.indices {
            for itemIndex in stacks[stackIndex].items.indices {
                let item = stacks[stackIndex].items[itemIndex]
                guard case let .file(path, bookmark, isOwned) = item.content,
                      let old = oldFolders.first(where: { path.hasPrefix($0) }) else { continue }
                let newPath = newFolder + path.dropFirst(old.count)
                stacks[stackIndex].items[itemIndex] = ShelfItem(
                    id: item.id, content: .file(path: newPath, bookmark: bookmark, isOwned: isOwned))
                changed = true
            }
        }
        return changed
    }

    /// A folder's path ending in "/", so a prefix test stops at a component.
    private static func folderPrefix(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stacks)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.error("could not save shelf index: \(error.localizedDescription)")
        }
    }
}

/// One thing dropped on the shelf, as the store takes it.
enum DroppedItem: Hashable, Sendable {
    case file(URL)
    case link(URL)
    case text(String)
}
