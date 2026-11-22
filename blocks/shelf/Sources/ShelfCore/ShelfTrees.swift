import BlockKit
import Foundation

/// The shelf's views as trees, from `ShelfView.swift` of the in-app block:
/// the expanded shelf (a header with the count and Clear, a horizontally
/// scrolling row of tiles, the empty state and the dashed drop outline) and
/// the count beside the notch. Pure: the block gathers the state.
enum ShelfTrees {
    static let width = 500.0
    static let height = 180.0
    /// The count beside the notch. Only the width matters. Kept narrow: the
    /// app menus can end about 45 pt from the notch, and the wing must not reach them.
    static let wingWidth = 42.0
    static let wingHeight = 32.0
    static let tileWidth = 76.0
    static let tileSide = 64.0

    static let white = WireColor("#FFFFFF")
    static let black = WireColor("#000000")

    /// One tile: a stack, or one item of the stack being shown.
    struct Tile {
        /// The `item` id, such as `stack:<uuid>`.
        let id: String
        let title: String
        /// The picture of the first item.
        let preview: ViewNode
        let count: Int
        let hasFiles: Bool
        let drag: ViewNode.ItemDrag
        /// A stack shown as one tile; false for a single item.
        let isStack: Bool
    }

    struct State {
        let itemCount: Int
        /// The drop outline: another app's drag is in progress.
        let isDropTarget: Bool
        /// Waiting for promised files after a release over the notch.
        let isReceiving: Bool
        /// The item count of the stack shown as single items, if any.
        let shownStackCount: Int?
        let tiles: [Tile]
    }

    // MARK: Expanded

    static func expanded(_ state: State) -> ViewNode {
        var area: [ViewNode] = [state.tiles.isEmpty ? emptyState(hidden: state.isDropTarget) : tiles(state.tiles)]
        if state.isDropTarget { area.append(dropOverlay) }
        // Padding 18 at the sides, 6 at the top and 14 at the bottom.
        return .vstack(spacing: 10, alignment: .start, padding: .init(horizontal: 18, top: 6, bottom: 14), [
            header(state),
            .frame(fill: .both, .zstack(area)),
        ])
    }

    private static func header(_ state: State) -> ViewNode {
        var row: [ViewNode] = []
        if let count = state.shownStackCount {
            row.append(ViewNode.button(id: "back", title: "Back", style: .plain, symbol: "chevron.left").help("Back to the shelf"))
            row.append(.text("\(count) items", style: .title))
        } else {
            row.append(.text("Shelf", style: .title))
            if state.itemCount > 0 {
                row.append(.styledText(state.itemCount == 1 ? "1 item" : "\(state.itemCount) items",
                                       size: 11, opacity: 0.5, monospacedDigits: true))
            }
        }
        row.append(.spacer())
        if state.isReceiving {
            row.append(ViewNode.spinner(.small).accessibilityLabel("Waiting for dropped files").help("Waiting for dropped files"))
        }
        if state.itemCount > 0 {
            row.append(ViewNode.button(id: "clear", title: "Clear").help("Remove everything from the shelf"))
        }
        return .hstack(spacing: 8, alignment: .firstTextBaseline, row)
    }

    private static func tiles(_ tiles: [Tile]) -> ViewNode {
        .scroll(.horizontal, .hstack(spacing: 10, alignment: .start, padding: .init(vertical: 2), tiles.map(tile)))
    }

    private static func emptyState(hidden: Bool) -> ViewNode {
        // Hidden under the drop outline; kept out of the tree then.
        guard !hidden else { return .spacer() }
        return .vstack(spacing: 6, [
            .symbol("tray.and.arrow.down", size: 26, weight: .light),
            .styledText("Drag files, links or text here to keep them", size: 12, weight: .medium, opacity: 0.5),
        ])
    }

    private static let dropOverlay = ViewNode.box(
        cornerRadius: 14, fillOpacity: 0.06, color: white,
        stroke: .init(color: WireColor("#FFFFFF", opacity: 0.7), width: 2, dash: [7, 5]),
        .frame(fill: .both, .capsule(fill: WireColor("#000000", opacity: 0.75), padding: .init(horizontal: 12, vertical: 6),
                                     .hstack(spacing: 6, [
                                         .symbol("tray.and.arrow.down.fill", size: 15, weight: .semibold),
                                         .text("Drop here", style: .title),
                                     ])))
    )

    // MARK: Tiles

    /// The tile as an `item`, with the remove button in its overlay: the
    /// app's item layer covers the item's child, so a button inside it could
    /// not be clicked. In the overlay it brightens with the tile's hover.
    static func tile(_ tile: Tile) -> ViewNode {
        var picture: [ViewNode] = [tile.preview]
        if tile.count > 1 {
            picture.append(.hstack(offset: .init(x: 4, y: 4), [
                .capsule(fill: white, padding: .init(horizontal: 5, vertical: 1),
                         .styledText("\(tile.count)", size: 10, weight: .bold, color: black, monospacedDigits: true)),
            ]))
        }
        let body = ViewNode.vstack(spacing: 0, [
            .frame(height: 4, .spacer(minLength: 0)),
            .vstack(spacing: 4, [
                .frame(width: tileSide, height: tileSide, .zstack(alignment: .bottomTrailing, picture)),
                .frame(width: tileWidth, .styledText(tile.title, size: 10, lineLimit: 1, truncation: .middle)),
            ]),
        ])
        // Always shown, not only on hover: on hover alone it was easy to miss.
        // 16 pt, black on white, at 0.6 until the pointer is on the tile.
        let remove = ViewNode.frame(fill: .both, alignment: .topTrailing, .hstack(offset: .init(x: 2, y: -2), [
            ViewNode.button(id: "remove:\(tile.id)", title: "Remove from the shelf", style: .plain, restOpacity: 0.6,
                            label: .symbol("xmark.circle.fill", size: 16, color: black, secondaryColor: white))
                .help("Remove from the shelf"),
        ]))
        return .item(
            id: tile.id, cornerRadius: 10, drag: tile.drag, menu: menu(tile),
            click: tile.isStack, doubleClick: tile.hasFiles, help: tile.title, overlay: remove,
            .frame(width: tileWidth, body)
        )
    }

    private static func menu(_ tile: Tile) -> [ActionItem] {
        var entries: [ActionItem] = []
        if tile.hasFiles { entries.append(ActionItem(id: "quickLook", title: "Quick Look")) }
        if tile.isStack { entries.append(ActionItem(id: "showItems", title: "Show Items")) }
        entries.append(ActionItem(id: "remove", title: tile.isStack ? "Remove Stack" : "Remove"))
        return entries
    }

    // MARK: Pictures

    /// A file's thumbnail or icon; a placeholder card until one exists.
    static func file(_ picture: ViewNode?) -> ViewNode {
        picture ?? card(.symbol("doc", size: 22))
    }

    /// A file that no longer exists.
    static let missingFile = card(.symbol("questionmark.square.dashed", size: 22))

    static func link(_ url: URL) -> ViewNode {
        card(.vstack(spacing: 4, padding: .init(horizontal: 4, vertical: 4), [
            .symbol("link", size: 18, weight: .medium),
            .styledText(url.host() ?? url.absoluteString, size: 9, weight: .medium, lineLimit: 2, alignment: .center),
        ]))
    }

    static func text(_ text: String) -> ViewNode {
        card(.frame(fill: .both, alignment: .topLeading,
                    .vstack(alignment: .start, padding: .init(horizontal: 5, vertical: 5), [
                        .styledText(String(text.prefix(160)), size: 8, lineLimit: 6),
                    ])))
    }

    private static func card(_ child: ViewNode) -> ViewNode {
        .box(width: tileSide, height: tileSide, cornerRadius: 8, fillOpacity: 0.12, child)
    }

    // MARK: Wing

    /// Beside the notch: a tray and the item count.
    static func wing(itemCount: Int, isReceiving: Bool) -> ViewNode {
        var row: [ViewNode] = [
            .symbol(itemCount == 0 ? "tray.and.arrow.down" : "tray.full.fill", size: 12, weight: .semibold),
        ]
        if itemCount > 0 {
            row.append(.styledText("\(itemCount)", size: 12, weight: .semibold, monospacedDigits: true))
        }
        if isReceiving { row.append(.spinner(.mini)) }
        return ViewNode.frame(fill: .both, .hstack(spacing: 3, row)).accessibilityLabel("Shelf, \(itemCount) items")
    }

    /// With the count off: a wing of no width and nothing in it.
    static let emptyWing = ViewNode.spacer(minLength: 0)
}
