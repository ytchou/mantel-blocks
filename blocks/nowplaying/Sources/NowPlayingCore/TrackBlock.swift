import BlockKit
import Foundation

/// Shows what is playing, for a few seconds, when the volume changes or a new
/// track starts: the track, the artist, the artwork when there is one, and
/// the volume. Runs in its own process; the app sends it `nowPlaying` and
/// `outputVolume` events and draws the peek it sends back.
public struct TrackBlock: Block {
    /// Setting keys, as in `manifest.json`. The app stores them as `nowplaying.<key>`.
    nonisolated static let showOnVolumeChange = "showOnVolumeChange"
    nonisolated static let showOnTrackChange = "showOnTrackChange"
    /// How long a peek stays.
    nonisolated static let seconds = 3.0

    public var id: String { "nowplaying" }

    nonisolated public init() {}

    public func start(_ ctx: Context) {
        let session = Session(ctx)
        ctx.on(.nowPlaying) { event in
            guard let change = event.nowPlaying else { return }
            session.nowPlayingChanged(change, replay: event.replay)
        }
        ctx.on(.outputVolume) { event in
            guard let change = event.outputVolume else { return }
            session.volumeChanged(change, replay: event.replay)
        }
    }
}

/// One run of the block: its state and the view it last sent.
@MainActor
final class Session {
    private let ctx: Context
    private var logic = NowPlayingLogic()
    /// The tree the app holds, so an unchanged view is not sent again.
    private var sentTree: ViewNode?
    /// The artwork's `image` node, so the bytes are hashed once per track.
    private var artwork: (bytes: Data, node: ViewNode)?

    init(_ ctx: Context) {
        self.ctx = ctx
    }

    func nowPlayingChanged(_ change: NowPlaying, replay: Bool) {
        readSettings()
        let outcome = logic.trackChanged(
            player: change.player, isPlaying: change.state == .playing,
            title: change.title, artist: change.artist, artwork: change.artwork, replay: replay
        )
        apply(outcome)
    }

    func volumeChanged(_ change: OutputVolume, replay: Bool) {
        readSettings()
        apply(logic.volumeChanged(change.volume, isMuted: change.isMuted, replay: replay))
    }

    /// Settings are on unless the app sent them off.
    private func readSettings() {
        logic.showOnVolumeChange = ctx.bool(TrackBlock.showOnVolumeChange) ?? true
        logic.showOnTrackChange = ctx.bool(TrackBlock.showOnTrackChange) ?? true
    }

    private func apply(_ outcome: NowPlayingLogic.Outcome) {
        switch outcome {
        case .show:
            let tree = makeTree()
            sentTree = tree
            // It answers a change just made. Shown later, after a drag or while
            // the pointer was on the shelf, it would answer nothing, so the app
            // withdraws it at once if another block holds the notch.
            ctx.present(
                peek: ViewSlot(width: PeekTree.width, height: PeekTree.height, root: tree),
                priority: .standard,
                for: TrackBlock.seconds,
                dismissIfNotShown: true
            )
        case .refresh:
            let tree = makeTree()
            guard tree != sentTree else { return }
            sentTree = tree
            ctx.update(peek: tree)
        case .dismiss:
            ctx.dismiss()
        case .none:
            break
        }
    }

    private func makeTree() -> ViewNode {
        PeekTree.root(
            title: logic.track?.title ?? "",
            subtitle: logic.subtitle,
            artwork: artworkNode(),
            volume: logic.volume,
            isMuted: logic.isMuted
        )
    }

    private func artworkNode() -> ViewNode? {
        guard let bytes = logic.track?.artwork else { return nil }
        if let artwork, artwork.bytes == bytes { return artwork.node }
        let node = ctx.image(bytes, size: PeekTree.artworkSize, cornerRadius: PeekTree.artworkRadius)
        artwork = (bytes, node)
        return node
    }
}
