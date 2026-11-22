import BlockKit
import BlockKitTesting
import Foundation
import Testing
@testable import NowPlayingCore

// The block's behaviour, ported from the in-app block's tests. Each test runs
// the block over `FakeHost`, as the app would, and some also check
// `NowPlayingLogic` directly.

// MARK: - Helpers

private func play(_ title: String, by artist: String = "Singer", in player: String = "Spotify", artwork: Data? = nil, replay: Bool = false) -> HostToBlock {
    .event(payload: .nowPlaying(.init(player: player, state: .playing, title: title, artist: artist, artwork: artwork)), replay: replay)
}

private func pause(_ player: String = "Spotify", title: String = "Song", artist: String = "Singer") -> HostToBlock {
    .event(payload: .nowPlaying(.init(player: player, state: .paused, title: title, artist: artist)), replay: false)
}

private func stop(_ player: String) -> HostToBlock {
    .event(payload: .nowPlaying(.init(player: player, state: .stopped)), replay: false)
}

private func volume(_ value: Double = 0.5, muted: Bool = false, replay: Bool = false) -> HostToBlock {
    .event(payload: .outputVolume(.init(volume: value, isMuted: muted)), replay: replay)
}

/// A running block, welcomed with `settings`.
private func start(settings: [String: SettingValue] = [:]) async throws -> FakeHost {
    let host = FakeHost()
    host.run(TrackBlock())
    try await host.welcome(settings: settings)
    return host
}

/// Sends `messages`, then waits until the block has handled them: the kit
/// answers a ping on the main queue after every message sent before it.
private func send(_ host: FakeHost, _ messages: HostToBlock...) async throws {
    for message in messages { try host.send(message) }
    let seq = host.received.filter(isPong).count + 1
    try host.send(.ping(seq: seq))
    _ = await host.waitFor { $0 == .pong(seq: seq) }
}

private func isPong(_ message: BlockToHost) -> Bool { if case .pong = message { true } else { false } }

private struct Shown {
    let priority: Priority
    let peek: ViewSlot?
    let opensAt: Level
    let seconds: Double?
    let dismissIfNotShown: Bool
}

private func presents(_ host: FakeHost) -> [Shown] {
    host.received.compactMap {
        if case let .present(priority, peek, _, _, opensAt, seconds, dismissIfNotShown, _, _) = $0 {
            Shown(priority: priority, peek: peek, opensAt: opensAt, seconds: seconds, dismissIfNotShown: dismissIfNotShown)
        } else { nil }
    }
}

private func updates(_ host: FakeHost) -> [ViewNode] {
    host.received.compactMap { if case let .update(peek, _, _) = $0 { peek } else { nil } }
}

/// The peek tree the app holds now: from the latest `present` or `update`.
private func latestTree(_ host: FakeHost) -> ViewNode? {
    host.received.reduce(nil) { tree, message in
        switch message {
        case let .present(_, peek, _, _, _, _, _, _, _): peek?.root ?? tree
        case let .update(peek, _, _): peek ?? tree
        default: tree
        }
    }
}

/// Every node in the tree, depth first.
private func allNodes(_ node: ViewNode?) -> [ViewNode] {
    guard let node else { return [] }
    return [node] + node.children.flatMap { allNodes($0) }
}

private func texts(_ node: ViewNode?) -> [String] {
    allNodes(node).compactMap { if case let .text(text, _) = $0.kind { text } else { nil } }
}

private func hasProgress(_ node: ViewNode?) -> Bool {
    allNodes(node).contains { if case .progress = $0.kind { true } else { false } }
}

// MARK: - Tests

@Test func trackChangePresentsPeekFor3Seconds() async throws {
    let host = try await start()
    try await send(host, play("Song"))

    let shown = presents(host)
    #expect(shown.count == 1)
    let first = try #require(shown.first)
    #expect(first.priority == .standard)
    #expect(first.peek?.width == 380)
    #expect(first.peek?.height == 52)
    #expect(first.seconds == 3)
    #expect(first.opensAt == .peek)
    #expect(first.dismissIfNotShown)
    #expect(texts(first.peek?.root) == ["Song", "Singer"])
    // No volume change yet: the volume is unknown, and the peek leaves out its bar.
    #expect(!hasProgress(first.peek?.root))

    // Next, back, or the song ending on its own: each is a new track.
    try await send(host, play("Second"))
    #expect(presents(host).count == 2)
    #expect(texts(latestTree(host)).first == "Second")
}

@Test func sameSongDoesNotPresentAgain() async throws {
    let host = try await start()
    try await send(host, play("Song"))
    // The system source reports the same song again.
    try await send(host, play("Song", artwork: Data([1, 2, 3])))
    #expect(presents(host).count == 1)

    // A pause and play of the same song is not a new track either.
    try await send(host, pause(), play("Song"))
    #expect(presents(host).count == 1)
}

@Test func pauseDismisses() async throws {
    let host = try await start()
    try await send(host, play("Song"), pause())
    #expect(host.received.last(where: { !isPong($0) }) == .dismiss)

    // A stop dismisses too.
    try await send(host, play("Other"), stop("Spotify"))
    #expect(host.received.last(where: { !isPong($0) }) == .dismiss)
}

@Test func volumeChangeShowsTrackWithBar() async throws {
    let host = try await start()
    // Nothing plays: a volume change shows nothing.
    try await send(host, volume())
    #expect(presents(host).isEmpty)

    try await send(host, play("Song"), volume(0.5))
    let shown = presents(host)
    #expect(shown.count == 2)
    let tree = shown.last?.peek?.root
    #expect(texts(tree).first == "Song")
    let bar = allNodes(tree).first { if case .progress = $0.kind { true } else { false } }
    #expect(bar?.kind == .progress(value: 0.5, width: 64))
    #expect(bar?.accessibilityLabel == "Volume 50 percent")
    #expect(allNodes(tree).contains { $0.kind == .symbol(name: "speaker.wave.2.fill", size: 12, opacity: 0.8, width: 18) })

    // Muted: an empty bar and the muted speaker.
    try await send(host, volume(0.5, muted: true))
    let muted = presents(host).last?.peek?.root
    #expect(allNodes(muted).contains { $0.kind == .progress(value: 0, width: 64) && $0.accessibilityLabel == "Muted" })
    #expect(allNodes(muted).contains { $0.kind == .symbol(name: "speaker.slash.fill", size: 12, opacity: 0.8, width: 18) })
}

@Test func lastStartedPlayerWins() async throws {
    // The logic on its own.
    var logic = NowPlayingLogic()
    _ = logic.trackChanged(player: "Spotify", isPlaying: true, title: "Song", artist: "Singer", artwork: nil, replay: false)
    _ = logic.trackChanged(player: "Google Chrome", isPlaying: true, title: "Video", artist: "", artwork: nil, replay: false)
    #expect(logic.track?.player == "Google Chrome")
    // A video often has no artist: the player is shown instead.
    #expect(logic.subtitle == "Google Chrome")
    // Spotify pauses: the video is still shown, in place.
    #expect(logic.trackChanged(player: "Spotify", isPlaying: false, title: "", artist: "", artwork: nil, replay: false) == .refresh)
    #expect(logic.track?.title == "Video")

    // Through the app.
    let host = try await start()
    try await send(host, play("Song"), play("Video", by: "Channel", in: "Google Chrome"))
    #expect(texts(latestTree(host)).first == "Video")
    #expect(presents(host).count == 2)

    // The video pauses: the song is shown again, in place, without a new peek.
    try await send(host, pause("Google Chrome", title: "Video", artist: "Channel"))
    #expect(texts(latestTree(host)).first == "Song")
    #expect(presents(host).count == 2)
    #expect(!updates(host).isEmpty)

    // A volume change shows it anew.
    try await send(host, volume())
    #expect(presents(host).count == 3)
}

@Test func artworkCarriedOverForSameSong() async throws {
    let art = Data([1, 2, 3])
    let id = Assets.id(for: art)
    let host = try await start()
    try await send(host, play("Song"), play("Song", artwork: art))
    #expect(allNodes(latestTree(host)).contains { $0.kind == .image(asset: id, size: 36, cornerRadius: 8) })
    #expect(host.received.contains(.asset(id: id, bytes: art)))

    // The player's own source again, without artwork: the artwork stays.
    try await send(host, play("Song"), volume())
    let tree = presents(host).last?.peek?.root
    #expect(allNodes(tree).contains { $0.kind == .image(asset: id, size: 36, cornerRadius: 8) })
    // Sent once.
    #expect(host.received.filter { if case .asset = $0 { true } else { false } }.count == 1)
}

@Test func noArtworkShowsPlaceholderBox() async throws {
    let placeholder = ViewNode.box(width: 36, height: 36, cornerRadius: 8, fillOpacity: 0.12,
                                   .symbol("music.note", size: 15, opacity: 0.8))
    let direct = PeekTree.root(title: "Song", subtitle: "Singer", artwork: nil, volume: nil, isMuted: false)
    #expect(direct.children.first == placeholder)

    let host = try await start()
    try await send(host, play("Song"))
    #expect(latestTree(host)?.children.first == placeholder)
}

@Test func replayedEventsNeverPresent() async throws {
    let host = try await start()
    try await send(host, play("Song", replay: true), volume(0.3, replay: true))
    #expect(presents(host).isEmpty)

    // The replayed track is known: a real volume change shows it.
    try await send(host, volume(0.5))
    #expect(presents(host).count == 1)
    #expect(texts(latestTree(host)).first == "Song")

    // The replayed song was already seen: the same song live is not a new track.
    try await send(host, play("Song"))
    #expect(presents(host).count == 1)
}

@Test func settingsTurnEachTriggerOff() async throws {
    // Track changes off: no peek on a track, a peek on a volume change.
    let noTrack = try await start(settings: ["showOnTrackChange": .bool(false), "showOnVolumeChange": .bool(true)])
    try await send(noTrack, play("Song"))
    #expect(presents(noTrack).isEmpty)
    try await send(noTrack, volume())
    #expect(presents(noTrack).count == 1)

    // Volume changes off: a peek on a track, none on a volume change.
    let noVolume = try await start(settings: ["showOnTrackChange": .bool(true), "showOnVolumeChange": .bool(false)])
    try await send(noVolume, play("Song"))
    #expect(presents(noVolume).count == 1)
    try await send(noVolume, volume())
    #expect(presents(noVolume).count == 1)

    // A change the user makes while the block runs takes effect at once.
    try await send(noVolume, .setting(key: "showOnVolumeChange", value: .bool(true)), volume())
    #expect(presents(noVolume).count == 2)
}

@Test func manifestMatchesShippedKeys() throws {
    // Blocks/NowPlaying/manifest.json, from Tests/NowPlayingTests/NowPlayingTests.swift.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "manifest.json")
    let manifest = try Manifest.decode(Data(contentsOf: url))

    #expect(manifest.id == "nowplaying")
    #expect(manifest.name == "Now Playing")
    #expect(manifest.symbol == "music.note")
    #expect(manifest.executable == "NowPlaying")
    #expect(Set(manifest.events) == ["nowPlaying", "outputVolume"])
    let toggles = manifest.settings.filter { $0.type == .toggle }
    #expect(toggles.map(\.key) == [TrackBlock.showOnVolumeChange, TrackBlock.showOnTrackChange])
    #expect(toggles.map(\.key) == ["showOnVolumeChange", "showOnTrackChange"])
    #expect(toggles.allSatisfy { $0.default == .bool(true) })
    #expect(toggles.map(\.title) == ["Show when the volume changes", "Show when a new track starts"])
    #expect(manifest.settings.filter { $0.type == .note }.count == 1)
    #expect(manifest.settings.count == 3)
}
