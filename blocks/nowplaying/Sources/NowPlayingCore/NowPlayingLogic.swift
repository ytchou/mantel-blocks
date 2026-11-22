import Foundation

/// What the block knows about playback, and what each change asks of the
/// notch. A plain value with no kit import, so it is tested on its own.
///
/// Several players can report at once (Spotify, a browser); the one that
/// started playing last is shown.
struct NowPlayingLogic {
    struct Track: Equatable {
        var player: String
        var title: String
        var artist: String
        var artwork: Data?

        /// The same song in the same player, whatever the artwork.
        func isSameSong(as other: Track?) -> Bool {
            guard let other else { return false }
            return player == other.player && title == other.title && artist == other.artist
        }
    }

    /// What the block does after a change.
    enum Outcome: Equatable {
        /// Ask for the notch with the current track.
        case show
        /// Redraw what is on screen, in place.
        case refresh
        /// Nothing plays: give the notch back.
        case dismiss
        /// Nothing to draw.
        case none
    }

    var showOnVolumeChange = true
    var showOnTrackChange = true

    /// The track shown: the one that started playing last. Nil while nothing plays.
    private(set) var track: Track?
    /// Nil until the first volume change: the block only learns it from events.
    private(set) var volume: Double?
    private(set) var isMuted = false

    /// Each player's current track, while it plays.
    private var playing: [String: Track] = [:]
    /// Players in the order they started playing; the last one is shown.
    private var order: [String] = []
    /// The last song shown for a track change. A pause and play of the same
    /// song is not a new track.
    private var lastSong: Track?

    /// The artist, or the player when there is none (a video often has none).
    var subtitle: String {
        guard let track else { return "" }
        return track.artist.isEmpty ? track.player : track.artist
    }

    /// A player started, paused, stopped or changed track. A replayed event
    /// updates the state and never asks for the notch.
    mutating func trackChanged(player: String, isPlaying: Bool, title: String, artist: String, artwork: Data?, replay: Bool) -> Outcome {
        order.removeAll { $0 == player }
        if isPlaying {
            var new = Track(player: player, title: title, artist: artist, artwork: artwork)
            // Another source may have sent the artwork for this song already.
            if new.artwork == nil, let known = playing[player], known.isSameSong(as: new) {
                new.artwork = known.artwork
            }
            playing[player] = new
            order.append(player)
        } else {
            playing[player] = nil
        }
        track = order.last.flatMap { playing[$0] }

        guard let track else { return .dismiss }
        if track.player == player, isPlaying, !track.isSameSong(as: lastSong) {
            lastSong = track
            if showOnTrackChange, !replay { return .show }
        }
        // Shown already: the view updates in place.
        return .refresh
    }

    /// The output volume or mute changed. Shows the track, when one plays.
    mutating func volumeChanged(_ volume: Double, isMuted: Bool, replay: Bool) -> Outcome {
        self.volume = volume
        self.isMuted = isMuted
        guard track != nil else { return .none }
        return showOnVolumeChange && !replay ? .show : .refresh
    }
}
