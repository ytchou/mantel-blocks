import CoreGraphics
import Foundation
import Testing
@testable import RenameCore

private let utc = TimeZone(identifier: "UTC")!
private let date = Date(timeIntervalSince1970: 1_794_996_000)

/// A line `height` tall whose top edge is at `top` (0 bottom, 1 top).
private func line(_ text: String, top: Double, height: Double) -> RecognizedLine {
    RecognizedLine(text: text, box: CGRect(x: 0.1, y: top - height, width: 0.5, height: height))
}

private let dialog = [
    line("Payment Failed", top: 0.9, height: 0.06),
    line("Your card was declined by the bank", top: 0.8, height: 0.03),
    line("Contact support", top: 0.2, height: 0.03),
]

@Test func aClearTitleGivesScreenshotAppAndTitleWords() {
    let draft = FallbackNamer.draft(lines: dialog, appName: "Safari", date: date, timeZone: utc)
    #expect(draft == NameDraft(base: "Screenshot Safari payment failed", stamp: nil))
}

@Test func titleWordsAreLimitedToThree() {
    let lines = [line("Quarterly Revenue Growth Summary Report", top: 0.95, height: 0.08)]
    #expect(FallbackNamer.titleWords(in: lines) == ["quarterly", "revenue", "growth"])
}

@Test func withoutAClearTitleTheDateAndTimeAreUsed() {
    let even = (0..<6).map { line("Row \($0) of a busy table", top: 0.9 - Double($0) * 0.1, height: 0.03) }
    let draft = FallbackNamer.draft(lines: even, appName: nil, date: date, timeZone: utc)
    #expect(draft == NameDraft(base: "Screenshot", stamp: "2026-11-18-100000"))
}

@Test func noTextAtAllGivesTheDatedName() {
    let draft = FallbackNamer.draft(lines: [], appName: "Finder", date: date, timeZone: utc)
    #expect(draft == NameDraft(base: "Screenshot Finder", stamp: "2026-11-18-100000"))
}

@Test func stopWordsAndNumbersAreDropped() {
    #expect(FallbackNamer.words(in: "The invoice 2026 of the Month") == ["invoice", "month"])
}

@Test func chineseIsSplitIntoWordsNotCharacters() {
    let text = "台北捷運時刻表"
    let words = FallbackNamer.words(in: text)
    // If the tokenizer split per character, every token would be one
    // character long and dropped, leaving nothing.
    #expect(!words.isEmpty)
    #expect(words.allSatisfy { $0.count >= 2 && text.contains($0) })
}

@Test func theFallbackFileNameIsTidy() {
    let draft = FallbackNamer.draft(lines: dialog, appName: "Safari", date: date, timeZone: utc)
    let fileName = NameCleaner.fileName(
        base: draft.base, stamp: draft.stamp, options: NamingOptions(),
        appName: "Safari", date: date, timeZone: utc, fileExtension: "png"
    )
    #expect(fileName == "screenshot-safari-payment-failed.png")
}
