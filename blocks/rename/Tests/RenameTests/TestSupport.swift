import Foundation
import Synchronization
@testable import RenameCore

/// A new empty folder under the system temporary folder.
func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "RenameBlockTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
}

/// Write a small file and return its URL.
@discardableResult
func makeFile(_ name: String, in folder: URL, contents: String = "image") throws -> URL {
    let url = folder.appending(path: name, directoryHint: .notDirectory)
    try Data(contents.utf8).write(to: url)
    return url
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

struct FakeReader: TextReading {
    let body: @Sendable (URL) async throws -> [RecognizedLine]

    func readText(at url: URL) async throws -> [RecognizedLine] {
        try await body(url)
    }
}

struct FakeNamer: ScreenshotNaming {
    var status: ModelStatus = .available
    let body: @Sendable (NamingRequest) async throws -> String

    func suggestName(_ request: NamingRequest) async throws -> String {
        try await body(request)
    }
}

/// Collects values from any thread.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    func add(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] { storage.withLock { $0 } }
}

/// Let tasks run until `condition` holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
