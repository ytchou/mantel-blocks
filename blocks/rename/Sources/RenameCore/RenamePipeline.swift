import CoreGraphics
import Foundation
import ImageIO
import os
import Synchronization
import UniformTypeIdentifiers

/// One screenshot waiting to be named.
struct RenameJob: Sendable, Identifiable {
    let id = UUID()
    let url: URL
    let createdAt: Date
    /// The frontmost app when the screenshot arrived.
    let appName: String?
}

enum RenameOutcome: Sendable, Equatable {
    case renamed(from: URL, to: URL, usedFallback: Bool)
    /// The file went away before it could be renamed, or the job was cancelled.
    /// Dropped without a message.
    case dropped
    /// One line for the notch.
    case failed(String)
}

/// Read, name, rename. All of it runs off the main actor.
struct RenamePipeline: Sendable {
    let reader: any TextReading
    let namer: any ScreenshotNaming
    let renamer: Renamer
    /// For the model step. On time-out the fallback name is used.
    let timeLimit: Duration
    let timeZone: TimeZone

    private static let log = Logger(subsystem: "dev.mantel.Mantel", category: "rename")

    /// A small PNG of the screenshot for the peek, 96 px on the long side
    /// (a 36 pt square at 2x), sent to the app with `Context.image`.
    @concurrent
    func thumbnail(for url: URL) async -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // PNG encoding is copied in Shelf's Thumbnails on purpose: separate
        // packages, and BlockKit may import only Foundation, CryptoKit and Dispatch.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @concurrent
    func run(_ job: RenameJob, options: NamingOptions) async -> RenameOutcome {
        let log = Self.log
        let clock = ContinuousClock()
        guard FileManager.default.fileExists(atPath: job.url.path) else { return .dropped }

        let readStart = clock.now
        let lines: [RecognizedLine]
        do {
            lines = try await reader.readText(at: job.url)
            log.info("text read: \(lines.count) lines in \(Self.ms(clock.now - readStart)) ms")
        } catch {
            lines = []
            log.error("text reading failed after \(Self.ms(clock.now - readStart)) ms: \(String(describing: error), privacy: .private)")
        }
        guard !Task.isCancelled else { return .dropped }

        var draft: NameDraft?
        let status = namer.status
        if status.isAvailable, !lines.isEmpty {
            let request = NamingRequest(
                lines: lines.map(\.text),
                prominent: RecognizedLine.mostProminent(lines, count: NamingRequest.prominentCount),
                appName: options.appNameSuffix ? job.appName : nil,
                length: options.length,
                language: options.language
            )
            let namer = self.namer
            let modelStart = clock.now
            do {
                let words = try await withTimeLimit(timeLimit) { try await namer.suggestName(request) }
                let isEmpty = NameCleaner.slug(words).isEmpty
                if !isEmpty { draft = NameDraft(base: words) }
                log.info("model named in \(Self.ms(clock.now - modelStart)) ms, empty: \(isEmpty)")
            } catch is TimeLimitExceeded {
                log.info("model timed out after \(Self.ms(clock.now - modelStart)) ms; using fallback")
            } catch {
                log.error("model failed after \(Self.ms(clock.now - modelStart)) ms: \(String(describing: error), privacy: .private); using fallback")
            }
        } else {
            log.info("fallback naming: model \(String(describing: status), privacy: .public), lines \(lines.count)")
        }
        guard !Task.isCancelled else { return .dropped }

        let usedFallback = draft == nil
        let chosen = draft ?? FallbackNamer.draft(lines: lines, appName: job.appName, date: job.createdAt, timeZone: timeZone)
        let fileName = NameCleaner.fileName(
            base: chosen.base,
            stamp: chosen.stamp,
            options: options,
            appName: job.appName,
            date: job.createdAt,
            timeZone: timeZone,
            fileExtension: job.url.pathExtension
        )

        do {
            let target = try renamer.rename(job.url, to: fileName)
            log.info("renamed \(job.url.lastPathComponent, privacy: .private) to \(target.lastPathComponent, privacy: .private), fallback: \(usedFallback)")
            return .renamed(from: job.url, to: target, usedFallback: usedFallback)
        } catch RenameError.fileMissing {
            log.info("screenshot gone before rename; dropped")
            return .dropped
        } catch {
            log.error("rename failed: \(String(describing: error), privacy: .private)")
            return .failed((error as? RenameError)?.message ?? RenameError.failed("").message)
        }
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

// MARK: - Time limit

struct TimeLimitExceeded: Error {}

/// Run `operation`, giving up after `limit` with `TimeLimitExceeded`.
///
/// Unlike a task group, this returns at the limit even when the operation
/// ignores cancellation; the operation is cancelled and left to finish alone.
func withTimeLimit<T: Sendable>(
    _ limit: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    let work = Task {
        do {
            let value = try await operation()
            race.finish(.success(value))
        } catch {
            race.finish(.failure(error))
        }
    }
    let timer = Task {
        do { try await Task.sleep(for: limit) } catch { return }
        race.finish(.failure(TimeLimitExceeded()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await race.value()
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first result wins; later ones are ignored.
private final class Race<T: Sendable>: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<T, any Error>)
        case finished(Result<T, any Error>)
        case delivered
    }

    private let state = Mutex<State>(.pending)

    func finish(_ result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { state in
            switch state {
            case .pending:
                state = .finished(result)
                return nil
            case let .waiting(continuation):
                state = .delivered
                return continuation
            case .finished, .delivered:
                return nil
            }
        }
        continuation?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<T, any Error>? = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return nil
                case let .finished(result):
                    state = .delivered
                    return result
                case .waiting, .delivered:
                    return .failure(CancellationError())
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
