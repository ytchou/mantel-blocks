import Foundation

/// One held thing: a file or folder, a link, or a text snippet.
struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        /// A file or folder, held by reference. `bookmark` follows the file if
        /// it is moved or renamed; `path` is the fallback when it does not
        /// resolve. `isOwned` marks a file in the shelf's own storage (a moved
        /// promise file), which the shelf may delete; a user's file never is.
        case file(path: String, bookmark: Data?, isOwned: Bool)
        case link(URL)
        case text(String)
    }

    let id: UUID
    let content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    var isFile: Bool {
        if case .file = content { true } else { false }
    }

    var isOwnedFile: Bool {
        if case let .file(_, _, isOwned) = content { isOwned } else { false }
    }
}

/// Items dropped together. Shown as one tile and dragged out as one drag.
struct ShelfStack: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var items: [ShelfItem]
    let addedAt: Date

    init(id: UUID = UUID(), items: [ShelfItem], addedAt: Date = Date()) {
        self.id = id
        self.items = items
        self.addedAt = addedAt
    }
}

/// What a drag-out, removal or preview acts on: a whole stack or one item.
enum ShelfTarget: Hashable, Sendable {
    case stack(UUID)
    case item(UUID)
}
