import Foundation

/// One rename the block made, for the recent list and undo.
struct RecentRename: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var folderPath: String
    var newName: String
    var originalName: String
    var renamedAt: Date
    var usedFallback: Bool
    var reverted = false

    var renamedURL: URL {
        URL(filePath: folderPath, directoryHint: .isDirectory).appending(path: newName, directoryHint: .notDirectory)
    }
}

/// The recent renames as JSON, newest first, in `recents.json` in the data
/// folder the app gives the block (the app moved the old
/// `Mantel/Rename` folder there).
struct RecentsStore: Sendable {
    static let limit = 20
    static let fileName = "recents.json"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(dataFolder: URL) {
        url = dataFolder.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    /// An empty list when the file is missing or unreadable.
    func load() -> [RecentRename] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RecentRename].self, from: data)).map { Array($0.prefix(Self.limit)) } ?? []
    }

    func save(_ items: [RecentRename]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(items.prefix(Self.limit)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
