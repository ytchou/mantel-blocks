import BlockKit
import CoreGraphics
import Foundation
import Synchronization
@testable import NowPlayingCore
@testable import RenameCore
@testable import ShelfCore

// The real blocks, run in this process. This file imports the blocks and
// BlockKit but not NotchCore: both have a `DroppedItem`. `TestSupport.swift`
// wires them to the runtime.

/// One block, run in this process by the BlockKit runner, as its
/// executable runs it on fd 3. Each launch is a new "process": a new block
/// value and a new connection; what the block stores in its data folder is
/// kept across launches, as on disk.
@MainActor
final class InProcessBlock {
    let manifest: Manifest
    /// The app's end of the current process's connection.
    private(set) var link: SyncedTransport?
    private var life: ProcessLife?
    private let make: @MainActor (ProcessLife) -> any Block

    /// - Parameters:
    ///   - folder: the block's folder under `blocks/` (its id), whose
    ///     `manifest.json` is read, so these tests follow it when it changes.
    ///   - make: the block for one process.
    init(folder: String, make: @escaping @MainActor (ProcessLife) -> any Block) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CollisionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // collisions
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // repository root
            .appending(path: "blocks/\(folder)/manifest.json")
        do {
            manifest = try Manifest.decode(Data(contentsOf: url))
        } catch {
            fatalError("Could not read the manifest at \(url.path): \(error)")
        }
        self.make = make
    }

    /// The launcher: a new process of the real block.
    func launch(generation: Int) -> any Transport {
        let (app, block) = MemoryTransport.pair()
        let life = ProcessLife()
        let link = SyncedTransport(app, generation: generation)
        self.life = life
        self.link = link
        let runner = Runner(block: make(life), transport: block, generation: generation)
        Task {
            await runner.run()
            life.end()
        }
        return link
    }

    /// True while the current process runs: until the app sends `quit` or
    /// closes the connection.
    var isRunning: Bool { life.map { !$0.hasEnded } ?? false }
}

/// Whether one block process has ended. In the app the process exits then,
/// and whatever it was doing stops with it; here its tasks live on, so the
/// fakes it was given check this.
final class ProcessLife: Sendable {
    private let ended = Mutex(false)

    var hasEnded: Bool { ended.withLock { $0 } }

    func end() { ended.withLock { $0 = true } }
}

/// The app's end of the connection to an in-process block. It counts the
/// frames the app sends, and `sync()` tells when the block and its stand-in
/// have handled everything sent so far.
///
/// `sync()` sends a `ping` with a negative `seq`. The kit answers a ping on
/// the main queue after every message sent before it, so the `pong` comes
/// after every frame the block sent in answer. The stand-in ignores a pong
/// with a negative `seq`. Its reader asks for the next frame only after it
/// handled the one before, so once it asks for the frame after that pong,
/// it has handled every frame up to it.
final class SyncedTransport: Transport, @unchecked Sendable {
    // @unchecked: `Shared` guards the counts; the iterator has one consumer,
    // as `frames` has.
    private struct Counts {
        var sent = 0
        var syncsSent = 0
        var syncsHandled = 0
        /// The sync pong last handed to the reader, not yet known handled.
        var handedSync: Int?
    }

    private final class IteratorBox: @unchecked Sendable {
        var base: AsyncThrowingStream<Data, any Error>.AsyncIterator
        init(_ base: AsyncThrowingStream<Data, any Error>.AsyncIterator) { self.base = base }
        func next() async throws -> Data? { try await base.next() }
    }

    private let base: MemoryTransport
    private let generation: Int
    /// The counts shared with the `frames` closure.
    private let shared: Shared
    let frames: AsyncThrowingStream<Data, any Error>

    init(_ base: MemoryTransport, generation: Int) {
        self.base = base
        self.generation = generation
        let shared = Shared()
        let iterator = IteratorBox(base.frames.makeAsyncIterator())
        frames = AsyncThrowingStream {
            shared.handedFrameHandled()
            guard let body = try await iterator.next() else { return nil }
            if case let .pong(seq)? = try? Framing.decode(body, as: BlockToHost.self).message, seq < 0 {
                shared.handed(sync: -seq)
            }
            return body
        }
        self.shared = shared
    }

    private final class Shared: Sendable {
        private let state = Mutex(Counts())

        func handedFrameHandled() {
            state.withLock { s in
                if let handed = s.handedSync { s.syncsHandled = max(s.syncsHandled, handed) }
                s.handedSync = nil
            }
        }

        func handed(sync: Int) { state.withLock { $0.handedSync = sync } }

        func sentOne() { state.withLock { $0.sent += 1 } }

        func nextSync() -> Int {
            state.withLock { s in
                s.syncsSent += 1
                return s.syncsSent
            }
        }

        var sent: Int { state.withLock { $0.sent } }
        var isSynced: Bool { state.withLock { $0.syncsHandled >= $0.syncsSent } }
    }

    /// Frames the app sent, not counting syncs.
    var sentCount: Int { shared.sent }

    /// True once the stand-in handled the pong of the last `sync()`.
    var isSynced: Bool { shared.isSynced }

    func sync() {
        let seq = shared.nextSync()
        try? base.send(HostToBlock.ping(seq: -seq), generation: generation)
    }

    func send(_ body: Data) throws(FramingError) {
        shared.sentOne()
        try base.send(body)
    }

    func close() { base.close() }
}

// MARK: - The three blocks

extension InProcessBlock {
    /// The shelf, as shipped, without Quick Look thumbnails.
    static func shelf() -> InProcessBlock {
        InProcessBlock(folder: "shelf") { _ in
            ShelfBlock(lateDropGrace: ShelfBlock.defaultLateDropGrace, thumbnailer: .none)
        }
    }

    /// The rename block with its slow parts faked: reading a screenshot
    /// waits for `gate`, then finds the text of a failed payment, which the
    /// model names "payment failed dialog". Each file becomes
    /// `payment-failed-dialog.png`, with a number when the name is taken.
    static func rename(gate: Gate) -> InProcessBlock {
        InProcessBlock(folder: "rename") { life in
            RenameBlock(reader: GatedReader(gate: gate, life: life), namer: FixedNamer())
        }
    }

    static func nowPlaying() -> InProcessBlock {
        InProcessBlock(folder: "nowplaying") { _ in TrackBlock() }
    }
}

/// Holds every reading until `open()` is called, then answers at once.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Reads a screenshot once the gate opens. Not on the model's clock, so a
/// closed gate never makes the block fall back to a dated name.
private struct GatedReader: TextReading {
    let gate: Gate
    let life: ProcessLife

    func readText(at url: URL) async throws -> [RecognizedLine] {
        await gate.wait()
        // The process ended meanwhile: in the app it exited, and the file
        // keeps its name. Hold the job for good instead of finishing it.
        while life.hasEnded {
            try await Task.sleep(for: .seconds(3600))
        }
        return [RecognizedLine(text: "Payment Failed", box: CGRect(x: 0.1, y: 0.84, width: 0.5, height: 0.06))]
    }
}

private struct FixedNamer: ScreenshotNaming {
    var status: ModelStatus { .available }

    func suggestName(_ request: NamingRequest) async throws -> String { "payment failed dialog" }
}

// MARK: - What the blocks keep

/// What the blocks store in their data folders and how long they ask to be
/// shown, read the way the blocks read them.
enum BlockState {
    /// The items on the shelf whose data folder this is.
    @MainActor
    static func shelfItemCount(dataFolder: URL) -> Int {
        let index = dataFolder.appending(path: "index.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: index),
              let stacks = try? JSONDecoder().decode([ShelfStack].self, from: data) else { return 0 }
        return stacks.reduce(0) { $0 + $1.items.count }
    }

    /// The rename block's new names, newest first, kept across processes.
    static func renamedNames(dataFolder: URL) -> [String] {
        RecentsStore(dataFolder: dataFolder).load().map(\.newName)
    }

    /// How long a rename result stays: `RenameBlock.resultDuration`.
    static let renameResultDuration: Duration = .seconds(RenameBlock.resultDuration)
    /// How long a now-playing peek stays: `TrackBlock.seconds`.
    static let nowPlayingDuration: Duration = .seconds(TrackBlock.seconds)
}
