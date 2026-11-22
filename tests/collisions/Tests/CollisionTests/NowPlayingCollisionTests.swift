import Foundation
import Testing
@testable import NotchCore

// A volume change while the shelf or the rename block has the notch.
// All three blocks run in one runtime as stand-ins, as in the app; behind
// each stand-in runs the real block's code. Each event waits until the
// blocks have answered, so a check that nothing changed is real.

@MainActor
private func spotifyPlays(_ f: Fixture) async {
    await f.publish(NowPlayingChanged(player: "Spotify", state: .playing, title: "Song", artist: "Singer"))
}

@MainActor
private func volumeChanges(_ f: Fixture) async {
    await f.publish(OutputVolumeChanged(volume: 0.5, isMuted: false))
}

@MainActor
@Test func aVolumeChangeDoesNotTakeTheNotchFromAShelfInUse() async throws {
    let f = try Fixture()
    await f.publish(DragSessionStarted(kinds: [.text]))
    await f.drop([.text("held")])
    await f.publish(DragSessionEnded())
    await f.hover(true)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    await spotifyPlays(f)
    await volumeChanges(f)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // When the pointer leaves, the late volume change is not shown.
    await f.hover(false)
    #expect(f.runtime.state.owner == "shelf")
}

@MainActor
@Test func aVolumeChangeDuringADragLeavesTheDropTarget() async throws {
    let f = try Fixture()
    await spotifyPlays(f)
    await f.publish(DragSessionStarted(kinds: [.file]))
    #expect(f.runtime.state.owner == "shelf")

    await volumeChanges(f)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    // Nothing was dropped: the notch goes back to rest, not to a stale track.
    await f.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == nil)
}

@MainActor
@Test func aNewTrackDuringADragIsNotShownLater() async throws {
    let f = try Fixture()
    await f.publish(DragSessionStarted(kinds: [.file]))
    await spotifyPlays(f)
    #expect(f.runtime.state.owner == "shelf")
    #expect(f.runtime.state.level == .expanded)

    await f.publish(DragSessionEnded())
    #expect(f.runtime.state.owner == nil)
}

@MainActor
@Test func aVolumeChangeDuringARenameResultShowsAndTheResultReturns() async throws {
    let f = try Fixture()
    await spotifyPlays(f)
    // The track's own peek ranks above the rename block: let it end first.
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: BlockState.nowPlayingDuration)
    await waitUntil { f.runtime.state.owner == nil }
    await f.capture(try makeScreenshot("Screenshot 1.png", in: f.folder))
    await f.waitFor { !f.renamedNames.isEmpty }
    #expect(f.runtime.state.owner == "rename")

    // Now Playing ranks above Screenshot Names: the volume change shows.
    await volumeChanges(f)
    #expect(f.runtime.state.owner == "nowplaying")
    #expect(f.runtime.state.presentation?.duration == BlockState.nowPlayingDuration)

    // Its time runs out: the rename result is back, with its time.
    await waitUntil { f.clock.sleeperCount > 0 }
    f.clock.advance(by: BlockState.nowPlayingDuration)
    await waitUntil { f.runtime.state.owner == "rename" }
    #expect(f.runtime.state.owner == "rename")
    #expect(f.runtime.state.presentation?.duration == BlockState.renameResultDuration)
}
