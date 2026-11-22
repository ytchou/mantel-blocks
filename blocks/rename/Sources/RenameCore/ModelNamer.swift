import Foundation
import FoundationModels

/// Whether the on-device model can name screenshots, and if not, why.
enum ModelStatus: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable

    var isAvailable: Bool { self == .available }

    /// One plain sentence for the settings pane.
    var explanation: String {
        switch self {
        case .available:
            "The on-device model is ready. Names describe what the screenshot shows."
        case .deviceNotEligible:
            "This Mac cannot run Apple Intelligence, so screenshots get simple dated names."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off. Turn it on in System Settings for descriptive names."
        case .modelNotReady:
            "The on-device model is still downloading or getting ready. Simple dated names are used until then."
        case .unavailable:
            "The on-device model is not available, so screenshots get simple dated names."
        }
    }
}

/// What the namer gets for one screenshot.
struct NamingRequest: Sendable, Equatable {
    /// Lines of the biggest text sent first.
    static let prominentCount = 6

    /// Recognised lines, top to bottom.
    var lines: [String]
    /// The biggest text on screen, most prominent first: titles and headings.
    var prominent: [String] = []
    var appName: String?
    var length: NameLength
    var language: NameLanguage
}

/// Suggests descriptive words for a screenshot.
protocol ScreenshotNaming: Sendable {
    var status: ModelStatus { get }
    /// Words for the name, before cleaning. May be slow; honours cancellation.
    func suggestName(_ request: NamingRequest) async throws -> String
}

extension NameLength {
    /// Words the model is asked for, and the most kept.
    var wordRange: ClosedRange<Int> {
        switch self {
        case .short: 2...4
        case .standard: 3...6
        case .long: 5...9
        }
    }
}

struct ModelNamerError: Error {
    let reason: String
}

/// Names a screenshot with Apple's on-device model (FoundationModels).
/// The API use follows the naming spike (`spikes/screenshot-naming/Sources/NameSpike/Namer.swift`).
///
/// Where the time goes (measured, `spikes/screenshot-naming/SPEED.md`):
/// writing the name takes about 50 ms and reading the prompt about 0.5 s
/// while the model is loaded. macOS unloads the model within some 10 s of
/// its last use, and loading it again takes 3 to 19 s, in steps of about 3 s.
/// Prompt length and response length did not change that reliably. Asking
/// for the model ahead with `prewarm` made names slower (text reading
/// stalled behind it), so the session is made when it is used.
struct ModelNamer: ScreenshotNaming {
    /// Characters of recognised text sent to the model. The biggest text is
    /// sent first anyway. CJK text can cost a token or more per character.
    static let textLimit = 1000
    /// Used once if the model reports that the context window was exceeded.
    static let retryTextLimit = 500

    var status: ModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unavailable
            }
        }
    }

    func suggestName(_ request: NamingRequest) async throws -> String {
        do {
            return try await generate(request, limit: Self.textLimit)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw error }
            return try await generate(request, limit: Self.retryTextLimit)
        }
    }

    private func generate(_ request: NamingRequest, limit: Int) async throws -> String {
        let text = Self.truncated(request.lines, limit: limit)
        // A session keeps its conversation, so each one names one screenshot.
        let session = LanguageModelSession(instructions: Self.instructions(for: request.language))
        // A plain short answer, not a guided list of a fixed length: measured
        // on real screenshots, a fixed count made the model pad the name with
        // menu words and repeats ("polling polling polling"), and was no faster.
        let stream = session.streamResponse(
            to: Self.prompt(text: text, prominent: request.prominent, appName: request.appName, length: request.length),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.maxResponseTokens)
        )
        var last = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            last = snapshot.content
        }
        let words = Self.words(in: last, max: request.length.wordRange.upperBound)
        guard !words.isEmpty else { throw ModelNamerError(reason: "no output") }
        return words.joined(separator: " ")
    }

    /// Enough for nine words; the model stops well before.
    static let maxResponseTokens = 32

    /// The name in the model's answer: its first line, lowercased, without
    /// quotes or repeated words, at most `max` words.
    static func words(in answer: String, max: Int) -> [String] {
        let firstLine = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*.:- ").union(.whitespaces))
        var seen = Set<String>()
        return trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { seen.insert($0).inserted }
            .prefix(max)
            .map { $0 }
    }

    static func instructions(for language: NameLanguage) -> String {
        let languageRule = switch language {
        case .matchContent: "Use the main language of the screenshot text."
        case .english: "Write the words in English, even when the screenshot text is in another language."
        case .traditionalChinese: "Write the words in Traditional Chinese (繁體中文), even when the screenshot text is in another language."
        }
        return """
        You name screenshot files. You get the text read from one screenshot.
        Name the subject: what the screenshot is about, such as a document, a page, an error, \
        a conversation, a chart or a product. Do not name the app around it, and do not copy the text.
        Put the subject first, then its context, most specific first.
        Ignore menus, tab titles, toolbar and button labels, timestamps, and browser or app chrome.
        Never include dates, times, file extensions or the word "screenshot".
        Examples of good names: "payment failed stripe checkout", "onboarding step two figma", \
        "invoice overdue acme", "flight confirmation sfo tokyo", "pull request review mantel".
        \(languageRule)
        """
    }

    static func prompt(text: String, prominent: [String], appName: String?, length: NameLength = .standard) -> String {
        var prompt = ""
        if let appName, !appName.isEmpty {
            prompt += "The screenshot was taken while \(appName) was the frontmost app.\n"
        }
        if !prominent.isEmpty {
            prompt += "The biggest text on screen, biggest first (titles and headings):\n"
            prompt += prominent.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        prompt += """
        All text, top to bottom (may be cut short):
        \"\"\"
        \(text)
        \"\"\"
        Name the file in \(length.wordRange.lowerBound) to \(length.wordRange.upperBound) words. \
        Reply with the name only, on one line, without punctuation.
        """
        return prompt
    }

    /// Whole lines, top to bottom, up to `limit` characters.
    static func truncated(_ lines: [String], limit: Int) -> String {
        var out: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + 1
            if used + cost > limit {
                let room = limit - used
                if room > 20 { out.append(String(line.prefix(room))) }
                break
            }
            out.append(line)
            used += cost
        }
        return out.joined(separator: "\n")
    }
}
