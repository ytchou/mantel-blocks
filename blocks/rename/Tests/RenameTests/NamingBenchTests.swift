import Foundation
import FoundationModels
import Testing
@testable import RenameCore

// Timing benches for the model step, not tests. They need Apple Intelligence
// and run only when asked for. Results: `spikes/screenshot-naming/SPEED.md`.
//
//   NAMING_BENCH_DIR=/folder/of/pngs make test FILTER=namingAfterIdle
//   NAMING_BENCH_LENGTHS=1 make test FILTER=namingLatencyByLength

/// A compact prompt that was tried and not kept: short instructions and
/// about 110 estimated tokens of text, to stay under 256 tokens in all.
private let compactInstructions = """
    You name a screenshot from the text read off it. Name the subject, most specific first: \
    what it is about, not the app around it. Ignore menus, buttons, tabs and timestamps. \
    No dates or file extensions. \
    Examples: "payment failed stripe checkout", "flight confirmation sfo tokyo".
    Use the main language of the text.
    """

/// 2 Latin characters a token, 1.5 tokens for any other character.
private func estimatedTokens(_ text: String) -> Int {
    let ascii = text.unicodeScalars.count(where: \.isASCII)
    return Int((Double(ascii) / 2 + Double(text.unicodeScalars.count - ascii) * 1.5).rounded(.up))
}

private func compactPrompt(lines: [String], prominent: [String], budget: Int = 110) -> String {
    var left = budget
    var big: [String] = []
    for line in prominent.map({ String($0.prefix(80)) }) {
        guard estimatedTokens(line) + 2 <= left else { break }
        big.append(line)
        left -= estimatedTokens(line) + 2
    }
    var rest: [String] = []
    for line in lines where !prominent.contains(line) {
        guard estimatedTokens(line) + 1 <= left else { break }
        rest.append(line)
        left -= estimatedTokens(line) + 1
    }
    return "Biggest text:\n" + big.map { "- \($0)" }.joined(separator: "\n")
        + "\nOther text:\n" + rest.joined(separator: "\n")
        + "\nName it in 3 to 6 words. Reply with the name only, on one line."
}

/// Each screenshot named two ways ("app" is `ModelNamer` as shipped), each after
/// the model sat idle (`NAMING_BENCH_GAP_S`, default 15 s), as in real use:
/// read the text, ask. `NAMING_BENCH_VARIANTS` picks two of app, warm, compact.
///   IDLE  file  variant  read_ms  model_ms  name
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMING_BENCH_DIR"] != nil))
func namingAfterIdle() async throws {
    let env = ProcessInfo.processInfo.environment
    let folder = URL(fileURLWithPath: env["NAMING_BENCH_DIR"]!)
    let gap = Duration.seconds(env["NAMING_BENCH_GAP_S"].flatMap(Int.init) ?? 15)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let clock = ContinuousClock()
    let reader = VisionTextReader()
    let namer = ModelNamer()

    for (index, file) in files.enumerated() {
        // Alternate which prompt goes first.
        let pair = (env["NAMING_BENCH_VARIANTS"] ?? "app,warm").split(separator: ",").map(String.init)
        for variant in index.isMultiple(of: 2) ? pair : pair.reversed() {
            try await Task.sleep(for: gap)
            let compact = LanguageModelSession(instructions: compactInstructions)
            // "warm" is the app before DEV-2066: ask for the model ahead.
            let warm = LanguageModelSession(instructions: ModelNamer.instructions(for: .matchContent))
            switch variant {
            case "compact": compact.prewarm()
            case "warm": warm.prewarm()
            default: break
            }

            let readStart = clock.now
            let lines = try await reader.readText(at: file)
            let readMs = ms(clock.now - readStart)
            let prominent = RecognizedLine.mostProminent(lines, count: NamingRequest.prominentCount)

            let start = clock.now
            var name: String
            do {
                if variant == "compact" {
                    let answer = try await compact.respond(
                        to: compactPrompt(lines: lines.map(\.text), prominent: prominent),
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
                    )
                    name = ModelNamer.words(in: answer.content, max: 6).joined(separator: " ")
                } else if variant == "warm" {
                    let answer = try await warm.respond(
                        to: ModelNamer.prompt(
                            text: ModelNamer.truncated(lines.map(\.text), limit: ModelNamer.textLimit),
                            prominent: prominent, appName: nil),
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: ModelNamer.maxResponseTokens)
                    )
                    name = ModelNamer.words(in: answer.content, max: 6).joined(separator: " ")
                } else {
                    name = try await namer.suggestName(NamingRequest(
                        lines: lines.map(\.text), prominent: prominent, appName: nil, length: .standard, language: .matchContent))
                }
            } catch {
                name = "ERROR \(error)".prefix(60).description
            }
            print("IDLE\t\(file.lastPathComponent)\t\(variant)\t\(readMs)\t\(ms(clock.now - start))\t\(name)")
        }
    }
}

/// Time to the first token against prompt length, back to back (model warm),
/// on text that is new each time so nothing is reused.
///   LENGTH  instructions  prompt_chars  first_token_ms  total_ms
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAMING_BENCH_LENGTHS"] != nil))
func namingLatencyByLength() async throws {
    let clock = ContinuousClock()
    let words = ["invoice", "meeting", "budget", "pipeline", "review", "launch", "report", "design", "customer", "release",
                 "holiday", "contract", "schedule", "server", "payment", "update", "garden", "ticket", "museum", "recipe"]
    for round in 0..<3 {
        for (instructions, label) in [(compactInstructions, "short"), (ModelNamer.instructions(for: .matchContent), "long")] {
            for length in [0, 100, 300, 600, 1000, 2000] {
                var text = ""
                while text.count < length { text += words.randomElement()! + (Int.random(in: 0..<8) == 0 ? "\n" : " ") }
                let prompt = "Text:\n\(text)\nName it in 3 to 6 words. Reply with the name only. Round \(round) \(Int.random(in: 0..<100_000))."
                let session = LanguageModelSession(instructions: instructions)
                let start = clock.now
                var first: Duration?
                let stream = session.streamResponse(to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 16))
                for try await _ in stream where first == nil { first = clock.now - start }
                print("LENGTH\t\(label)\t\(prompt.count)\t\(first.map(ms) ?? -1)\t\(ms(clock.now - start))")
            }
        }
    }
}

private func ms(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
}
