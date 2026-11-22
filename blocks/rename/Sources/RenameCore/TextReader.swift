import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text in an image.
protocol TextReading: Sendable {
    /// Lines top to bottom, then left to right.
    func readText(at url: URL) async throws -> [RecognizedLine]
}

struct TextReadingError: Error {
    let reason: String
}

/// On-device text recognition with Vision, set up as in the naming spike.
/// Measured: 0.9 s for a full 3024x1964 screen (`spikes/FINDINGS.md`, table C).
struct VisionTextReader: TextReading {
    func readText(at url: URL) async throws -> [RecognizedLine] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TextReadingError(reason: "cannot load image")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = Self.recognitionLanguages(preferred: Locale.preferredLanguages, supported: supported)
        if !languages.isEmpty { request.recognitionLanguages = languages }

        // `perform` is synchronous and blocks this (non-main) thread for up to
        // about a second; acceptable for one job at a time.
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: top.string, box: observation.boundingBox)
        }
        return lines.sorted { a, b in
            if abs(a.box.maxY - b.box.maxY) > 0.01 { return a.box.maxY > b.box.maxY }
            return a.box.minX < b.box.minX
        }
    }

    /// Traditional Chinese first (so mixed Chinese and English text is still
    /// read, as in the spike), then the user's languages, then US English;
    /// only those Vision supports, without repeats.
    static func recognitionLanguages(preferred: [String], supported: [String]) -> [String] {
        var wanted = ["zh-Hant"]
        for language in preferred {
            if let match = supported.first(where: { language == $0 || language.hasPrefix($0 + "-") }) {
                wanted.append(match)
            }
        }
        wanted.append("en-US")
        var seen = Set<String>()
        return wanted.filter { supported.contains($0) && seen.insert($0).inserted }
    }
}
