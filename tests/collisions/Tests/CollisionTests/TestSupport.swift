import BlockWire
import Foundation
import Synchronization
@testable import BlockHost
@testable import NotchCore

// The fixture: the three real blocks behind their stand-ins in one runtime.
// The blocks themselves are started in `RealBlocks.swift`.

/// A new empty folder under the system temporary folder.
func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "CollisionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
}

@discardableResult
func makeScreenshot(_ name: String, in folder: URL) throws -> URL {
    let url = folder.appending(path: name, directoryHint: .notDirectory)
    try Data("image".utf8).write(to: url)
    return url
}

/// All three blocks registered in one runtime, in this order: Now Playing,
/// Screenshot Names, Shelf, as if installed in that order with nothing
/// stored on the Blocks page. Each is a stand-in, as in the app,
/// whose process is the real block run in this process over an in-memory
/// connection (`InProcessBlock`).
///
/// A block answers in its own time, so every call that reaches a block
/// (`publish`, `drop`, `hover`, `setEnabled`) returns only once the blocks
/// handled it and the stand-ins handled their answers (`settle`).
@MainActor
struct Fixture {
    let runtime: NotchRuntime
    let clock: ManualClock
    let gate: Gate
    /// Where the screenshots are taken.
    let folder: URL
    /// The blocks' data folders, one per id.
    let data: URL
    /// The stand-ins, by id.
    let standIns: [BlockID: RemoteBlock]
    /// The block processes, in registration order.
    private let blocks: [InProcessBlock]

    /// `gateOpen: false` holds the reading of screenshots until `gate.open()`.
    init(gateOpen: Bool = true) throws {
        folder = try makeFolder()
        let data = try makeFolder()
        self.data = data
        clock = ManualClock()
        runtime = NotchRuntime(clock: clock)
        gate = Gate()
        if gateOpen { gate.open() }
        blocks = [.nowPlaying(), .rename(gate: gate), .shelf()]
        let suite = "CollisionTests-\(UUID().uuidString)"
        let runtime = self.runtime
        var standIns: [BlockID: RemoteBlock] = [:]
        for process in blocks {
            let block = RemoteBlock(
                manifest: process.manifest,
                packageURL: URL(fileURLWithPath: "/tmp/\(process.manifest.executable).mantelblock"),
                // Installed: Mantel ships no blocks (and no `.bundled`).
                // The stand-in only stores its source.
                source: .installed(from: "/tmp/\(process.manifest.executable).mantelblock"),
                dataFolder: data.appending(path: process.manifest.id),
                owner: { runtime.state.owner },
                launcher: { _, generation in process.launch(generation: generation) },
                defaults: UserDefaults(suiteName: suite)!,
                // A clock of its own that never moves: no heartbeat, and the
                // runtime's clock holds only presentation timers.
                clock: BlockClock(ManualClock())
            )
            runtime.register(block)
            standIns[block.id] = block
        }
        self.standIns = standIns
    }

    /// Publishes an event, and returns once everything it caused is handled.
    /// A drag event also sets the runtime's drag state first, as the drag
    /// monitor does.
    func publish<E: NotchEvent>(_ event: E) async {
        if event is DragSessionStarted { runtime.dragSessionChanged(active: true) }
        if event is DragSessionEnded { runtime.dragSessionChanged(active: false) }
        runtime.publish(event)
        await settle()
    }

    func capture(_ url: URL) async {
        await publish(ScreenshotCaptured(url: url, createdAt: Date()))
    }

    /// The pointer enters or leaves the notch; the shelf hears it.
    func hover(_ isInside: Bool) async {
        runtime.pointerHoverChanged(isInside: isInside)
        await settle()
    }

    /// Items dropped on the notch; the owner takes those its presentation accepts.
    func drop(_ items: [DroppedItem]) async {
        runtime.send(.drop(items))
        await settle()
    }

    /// Turns a block on or off; off returns once its process has ended.
    func setEnabled(_ id: BlockID, _ enabled: Bool) async {
        runtime.setEnabled(id, enabled)
        if !enabled, let process = blocks.first(where: { $0.manifest.id == id.rawValue }) {
            await waitUntil { !process.isRunning }
        }
        await settle()
    }

    /// Waits until each enabled stand-in is welcomed, then until a round of
    /// syncs (see `SyncedTransport`) passes in which the app sent no block
    /// anything else: every block handled every message, and every stand-in
    /// every answer.
    func settle() async {
        for _ in 0..<100 {
            let live = blocks.filter { runtime.isEnabled(BlockID(rawValue: $0.manifest.id)) }
            await waitUntil { live.allSatisfy { standIns[BlockID(rawValue: $0.manifest.id)]?.isWelcomed == true } }
            let links = live.compactMap { $0.isRunning ? $0.link : nil }
            let before = links.map(\.sentCount)
            links.forEach { $0.sync() }
            await waitUntil { links.allSatisfy(\.isSynced) }
            if links.map(\.sentCount) == before { return }
        }
    }

    /// Waits until `condition` holds, then until everything settled.
    func waitFor(_ condition: () -> Bool) async {
        await waitUntil(condition)
        await settle()
    }

    /// The names of the files in the screenshot folder, sorted.
    var screenshotNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The items the shelf holds, as it stored them.
    var shelfItemCount: Int { BlockState.shelfItemCount(dataFolder: data.appending(path: "shelf")) }

    /// The rename block's new names, newest first, as it stored them.
    var renamedNames: [String] { BlockState.renamedNames(dataFolder: data.appending(path: "rename")) }

    /// The rename block's peek, as its stand-in holds it, encoded as JSON
    /// so a test can look for a text in it.
    var renamePeek: String {
        guard let peek = standIns["rename"]?.model.peek, let json = try? JSONEncoder().encode(peek) else { return "" }
        return String(decoding: json, as: UTF8.self)
    }
}

/// Let tasks run until `condition` holds or about five seconds pass.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A clock that moves only when told to.
final class ManualClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private enum Outcome { case wait, ready, cancelled }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// Tasks asleep on this clock right now.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { s -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= s.now { return .ready }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .ready: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { s -> Sleeper? in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { s -> [Sleeper] in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
