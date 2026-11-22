import Foundation

enum RenameError: Error, Equatable {
    /// The file is no longer where it was.
    case fileMissing
    /// Undo cannot move the file back: another file has its original name.
    case originalNameTaken(String)
    /// The file at the renamed path is not the one this app renamed.
    case fileChanged
    /// The file system refused the move or the attribute.
    case failed(String)

    /// One line for the notch.
    var message: String {
        switch self {
        case .fileMissing: "The file is gone"
        case let .originalNameTaken(name): "\u{201C}\(name)\u{201D} already exists"
        case .fileChanged: "The file has changed"
        case .failed: "Could not rename the screenshot"
        }
    }
}

/// Renames files in place and back, keeping their dates. As in the naming
/// spike (`spikes/FINDINGS.md`, table C): a same-folder move, the creation and
/// modification dates set back exactly, and the original name stored in an
/// extended attribute so the file can be undone later and the screenshot
/// watcher does not treat it as a new screenshot.
struct Renamer: Sendable {
    static let originalNameAttribute = "com.mantel.original-name"

    /// Move `source` to `fileName` in its folder, or to `fileName-2`, `-3`, …
    /// when that is taken. Returns the new URL.
    func rename(_ source: URL, to fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let source = source.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else { throw RenameError.fileMissing }
        let folder = source.deletingLastPathComponent()
        let free = NameCleaner.resolveClash(fileName) { candidate in
            candidate != source.lastPathComponent
                && fileManager.fileExists(atPath: folder.appending(path: candidate).path)
        }
        let target = folder.appending(path: free, directoryHint: .notDirectory)
        guard target.path != source.path else { return source }

        let dates = Self.dates(of: source)
        // Keep the first original name across repeated renames, so undo goes back to it.
        // Written before the move, so the watcher never sees the new name without it.
        let existing = Self.readAttribute(source.path, Self.originalNameAttribute)
        let addedAttribute = existing == nil
        if addedAttribute, !Self.writeAttribute(source.path, Self.originalNameAttribute, Data(source.lastPathComponent.utf8)) {
            throw RenameError.failed("setxattr errno \(errno)")
        }
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            if addedAttribute { Self.removeAttribute(source.path, Self.originalNameAttribute) }
            if !fileManager.fileExists(atPath: source.path) { throw RenameError.fileMissing }
            throw RenameError.failed(String(describing: error))
        }
        Self.restore(dates, at: target)
        return target
    }

    /// Move a renamed file back to `originalName` and remove the attribute.
    /// Returns the restored URL.
    func undo(_ renamed: URL, originalName: String) throws -> URL {
        let fileManager = FileManager.default
        let renamed = renamed.standardizedFileURL
        guard fileManager.fileExists(atPath: renamed.path) else { throw RenameError.fileMissing }
        // Only a file this app renamed, and only back to a plain name in the
        // same folder: another file may have taken the path since.
        guard Self.originalName(of: renamed) == originalName,
              !originalName.contains("/"), originalName != "..", originalName != "." else {
            throw RenameError.fileChanged
        }
        let target = renamed.deletingLastPathComponent().appending(path: originalName, directoryHint: .notDirectory)
        if target.path != renamed.path {
            guard !fileManager.fileExists(atPath: target.path) else { throw RenameError.originalNameTaken(originalName) }
            let dates = Self.dates(of: renamed)
            do {
                try fileManager.moveItem(at: renamed, to: target)
            } catch {
                if !fileManager.fileExists(atPath: renamed.path) { throw RenameError.fileMissing }
                throw RenameError.failed(String(describing: error))
            }
            Self.restore(dates, at: target)
        }
        Self.removeAttribute(target.path, Self.originalNameAttribute)
        return target
    }

    /// The original name stored on a renamed file, if any.
    static func originalName(of url: URL) -> String? {
        readAttribute(url.path, originalNameAttribute).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Dates

    struct Dates: Equatable {
        var created: Date?
        var modified: Date?
    }

    static func dates(of url: URL) -> Dates {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Dates(created: attributes?[.creationDate] as? Date, modified: attributes?[.modificationDate] as? Date)
    }

    /// Set the dates back. A same-volume move normally keeps them; this makes
    /// sure. A failure here does not undo the rename: the name matters more.
    private static func restore(_ dates: Dates, at url: URL) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created = dates.created { attributes[.creationDate] = created }
        if let modified = dates.modified { attributes[.modificationDate] = modified }
        guard !attributes.isEmpty else { return }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    // MARK: Extended attributes

    static func readAttribute(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, size, 0, 0)
        }
        guard read >= 0 else { return nil }
        return data.prefix(read)
    }

    @discardableResult
    static func writeAttribute(_ path: String, _ name: String, _ value: Data) -> Bool {
        value.withUnsafeBytes { buffer in
            setxattr(path, name, buffer.baseAddress, value.count, 0, 0) == 0
        }
    }

    @discardableResult
    static func removeAttribute(_ path: String, _ name: String) -> Bool {
        removexattr(path, name, 0) == 0
    }
}
