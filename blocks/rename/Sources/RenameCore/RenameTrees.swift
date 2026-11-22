import BlockKit
import Foundation

/// What the rename block's views show. The block keeps it and builds both
/// trees from it each time it presents or updates.
struct RenameState {
    enum Phase: Equatable {
        case idle
        case naming
        case renamed(RecentRename)
        case failed(String)
    }

    var phase: Phase = .idle
    /// The file name of the screenshot being named.
    var currentName: String?
    /// The `image` node of the screenshot being named, once made.
    var thumbnail: ViewNode?
    /// Screenshots waiting behind the current one.
    var waiting = 0
    /// Newest first, at most `RecentsStore.limit`.
    var recents: [RecentRename] = []
    /// A revert from the list that failed.
    var listMessage: String?
}

/// How a file name reads in the notch. Files keep their names on disk
/// (kebab-case); the notch shows words, without the extension.
enum RenameDisplay {
    /// "shelf-rename-panel-ears.png" -> "Shelf Rename Panel Ears".
    static func words(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        // A name with spaces is already words (one macOS or the user gave).
        guard !stem.contains(" ") else { return stem }
        let parts = stem.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard parts.count > 1 else { return stem }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The name macOS gave it, without the extension.
    static func original(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }
}

/// The rename block's views as nodes, white on black, after the in-app
/// `RenameViews.swift` they replace: sizes, colours and opacities are the same.
enum RenameTrees {
    static let peekSize = (width: 420.0, height: 54.0)
    static let expandedSize = (width: 520.0, height: 260.0)

    /// The block's accent, after nameshot.app: amber on black.
    static let accent = WireColor("#F5A623")
    /// Text on the accent.
    static let onAccent = WireColor("#2B1700")
    static let faint = WireColor("#FFFFFF", opacity: 0.12)

    /// `NotchStyle.padding`, `.leadingImageSize`, `.leadingImageRadius`.
    static let padding = 18.0
    static let imageSize = 36.0
    static let imageRadius = 8.0
    /// `NotchStyle.secondary` is 11 pt; the views drew it at 0.55.
    static let secondarySize = 11.0
    static let secondaryOpacity = 0.55
    /// `NotchStyle.body` is 12 pt medium.
    static let bodySize = 12.0

    /// The Undo button in the peek.
    static let undoID = "undo"
    /// A Revert button in the list: this prefix and the rename's id.
    static let revertPrefix = "revert:"

    // MARK: Peek

    /// The peek, in three states: naming (the screenshot with a scan line and
    /// its original name), renamed (before and after, Undo and the time left
    /// to undo), and failed (why the name was kept).
    ///
    /// - Parameter undoWindow: seconds Undo stays, drawn as a bar that empties.
    static func peek(_ state: RenameState, undoWindow: Double = 6) -> ViewNode {
        var titleRow: [ViewNode] = []
        if showsSparkle(state.phase) {
            titleRow.append(.symbol("sparkle", size: 11, color: accent, weight: .bold))
        }
        titleRow.append(.text(title(state), style: .title))

        let row = ViewNode.hstack(padding: .init(horizontal: padding), [
            thumbnail(state),
            .vstack(spacing: 2, alignment: .start, [
                .hstack(spacing: 6, titleRow),
                subtitle(state),
            ]),
            .spacer(minLength: 4),
        ] + trailing(state))

        var layers: [ViewNode] = [.frame(fill: .both, row)]
        if case .renamed = state.phase {
            layers.append(.frame(fill: .both, alignment: .bottom, .vstack(padding: .init(horizontal: padding, vertical: 4), [
                .progress(1, color: accent, drainsOver: undoWindow, track: faint),
            ])))
        }
        return .zstack(alignment: .bottom, layers)
    }

    private static func showsSparkle(_ phase: RenameState.Phase) -> Bool {
        if case .failed = phase { false } else { true }
    }

    private static func title(_ state: RenameState) -> String {
        switch state.phase {
        case .idle, .naming: "Reading the screenshot\u{2026}"
        case let .renamed(item): RenameDisplay.words(item.newName)
        case .failed: "Kept the original name"
        }
    }

    private static func subtitle(_ state: RenameState) -> ViewNode {
        let attributes = ViewNode.TextAttributes(size: secondarySize, opacity: secondaryOpacity, lineLimit: 1, truncation: .middle)
        let runs: [ViewNode.TextRun] = switch state.phase {
        case .idle, .naming: [.init(state.currentName.map(RenameDisplay.original) ?? "")]
        case let .renamed(item): [.init("was "), .init(RenameDisplay.original(item.originalName), strikethrough: true)]
        case let .failed(message): [.init(message)]
        }
        return .styledText(runs, attributes)
    }

    private static func trailing(_ state: RenameState) -> [ViewNode] {
        switch state.phase {
        case .renamed:
            return [.button(
                id: undoID, title: "Undo", style: .accent, symbol: "arrow.uturn.backward",
                color: accent, labelColor: onAccent
            )]
        case .idle, .naming, .failed:
            guard state.waiting > 0 else { return [] }
            return [.capsule(fill: faint, padding: .init(horizontal: 9), height: 22,
                             .styledText("+\(state.waiting) next", size: 11, weight: .semibold, opacity: 0.7))]
        }
    }

    private static func thumbnail(_ state: RenameState) -> ViewNode {
        var isFailed = false
        if case .failed = state.phase { isFailed = true }
        var layers: [ViewNode] = []
        if let image = state.thumbnail {
            layers.append(image)
        } else {
            layers.append(.box(
                width: imageSize, height: imageSize, cornerRadius: imageRadius, fillOpacity: 0.12,
                isFailed
                    ? .symbol("exclamationmark.triangle", size: 15, color: accent)
                    : .symbol("camera.viewfinder", size: 15, opacity: 0.8)
            ))
        }
        if case .naming = state.phase { layers.append(.sweep(accent)) }
        return .frame(width: imageSize, height: imageSize, .zstack(layers))
    }

    // MARK: Recent renames

    /// The panel on hover: recent renames, newest first, each with its old name.
    ///
    /// - Parameters:
    ///   - fileExists: whether a renamed file is still there to revert.
    static func recents(
        _ state: RenameState,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ViewNode {
        var heading: [ViewNode] = [.text("Recent renames", style: .title), .spacer()]
        if state.phase == .naming {
            heading.append(.styledText(
                state.waiting > 0 ? "Naming\u{2026} +\(state.waiting)" : "Naming\u{2026}",
                size: secondarySize, color: accent
            ))
        }
        var content: [ViewNode] = [
            .vstack(spacing: 2, alignment: .start, [
                .hstack(alignment: .firstTextBaseline, heading),
                .styledText("Every rename can go back to its old name", size: secondarySize, opacity: secondaryOpacity),
            ]),
        ]
        if let message = state.listMessage {
            content.append(.styledText(message, size: secondarySize, color: accent, lineLimit: 1))
        }
        if state.recents.isEmpty {
            content.append(.styledText("New screenshots are named here.", size: bodySize, weight: .medium, opacity: secondaryOpacity))
            content.append(.spacer(minLength: 0))
        } else {
            let rows = state.recents.enumerated().map { index, item in
                row(item, isNewest: index == 0, canRevert: !item.reverted && fileExists(item.renamedURL))
            }
            content.append(.scroll(.vertical, .vstack(spacing: 12, rows)))
        }
        // Padding 18 at the sides and bottom, 6 at the top, as in the in-app view.
        return .frame(fill: .both, alignment: .topLeading,
                      .vstack(spacing: 12, alignment: .start, padding: .init(horizontal: padding, top: 6, bottom: padding), content))
    }

    private static func row(_ item: RecentRename, isNewest: Bool, canRevert: Bool) -> ViewNode {
        var nameRow: [ViewNode] = []
        if isNewest && !item.reverted {
            nameRow.append(.symbol("sparkle", size: 9, color: accent, weight: .bold))
        }
        nameRow.append(.styledText(
            item.reverted ? RenameDisplay.original(item.originalName) : RenameDisplay.words(item.newName),
            size: 12, weight: .semibold, opacity: item.reverted ? secondaryOpacity : nil, lineLimit: 1, truncation: .tail
        ))
        let trailing: ViewNode = item.reverted
            ? .styledText("Reverted", size: bodySize, weight: .medium, opacity: secondaryOpacity)
            : .button(id: revertPrefix + item.id.uuidString, title: "Revert", style: .capsule, enabled: canRevert)
        return .hstack([
            .vstack(spacing: 1, alignment: .start, [
                .hstack(spacing: 5, nameRow),
                .styledText(detail(item), size: secondarySize, opacity: secondaryOpacity, lineLimit: 1, truncation: .middle),
            ]),
            .spacer(minLength: 8),
            trailing,
        ])
    }

    private static func detail(_ item: RecentRename) -> String {
        if item.reverted { return "Name undone \u{00B7} was \(RenameDisplay.words(item.newName))" }
        let when = item.renamedAt.formatted(.relative(presentation: .named))
        return "\(RenameDisplay.original(item.originalName)) \u{00B7} \(when)"
    }
}
