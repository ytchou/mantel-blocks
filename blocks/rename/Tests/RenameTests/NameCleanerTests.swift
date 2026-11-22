import Foundation
import Testing
@testable import RenameCore

private let utc = TimeZone(identifier: "UTC")!
/// 2026-11-18 10:00:00 UTC.
private let day = Date(timeIntervalSince1970: 1_794_996_000)

private func name(
    _ base: String,
    stamp: String? = nil,
    length: NameLength = .standard,
    datePrefix: Bool = false,
    appSuffix: Bool = false,
    app: String? = nil,
    ext: String = "png"
) -> String {
    NameCleaner.fileName(
        base: base,
        stamp: stamp,
        options: NamingOptions(length: length, datePrefix: datePrefix, appNameSuffix: appSuffix),
        appName: app,
        date: day,
        timeZone: utc,
        fileExtension: ext
    )
}

@Test func theTestDateIsTheEighteenthInUTC() {
    #expect(NameCleaner.dayString(day, timeZone: utc) == "2026-11-18")
}

@Test func illegalCharactersBecomeSingleHyphens() {
    #expect(NameCleaner.slug("Payment: Failed / Error") == "payment-failed-error")
    #expect(NameCleaner.slug("..hidden\u{0007}\u{0000}name") == "hidden-name")
    #expect(NameCleaner.slug("  --a__b--  ") == "a-b")
    #expect(NameCleaner.slug("Don\u{2019}t panic") == "dont-panic")
}

@Test func namesAreCutToTheConfiguredNumberOfWords() {
    let base = "one two three four five six seven eight nine ten"
    #expect(name(base, length: .short) == "one-two-three.png")
    #expect(name(base, length: .standard) == "one-two-three-four-five.png")
    #expect(name(base, length: .long) == "one-two-three-four-five-six-seven-eight.png")
}

@Test func namesAreCappedAtEightyCharacters() {
    let base = Array(repeating: "abcdefghijklmno", count: 8).joined(separator: " ")
    let result = name(base, length: .long, datePrefix: true, appSuffix: true, app: "Google Chrome")
    let stem = String(result.dropLast(".png".count))
    #expect(stem.count <= 80)
    #expect(stem.hasPrefix("2026-11-18-"))
    #expect(stem.hasSuffix("-google-chrome"))
    #expect(!stem.contains("--"))
}

@Test func chineseCharactersAreKept() {
    #expect(NameCleaner.slug("台北 捷運 時刻表") == "台北-捷運-時刻表")
    #expect(name("台北捷運 時刻表") == "台北捷運-時刻表.png")
}

@Test func theDatePrefixIsAddedOnce() {
    #expect(name("payment failed", datePrefix: true) == "2026-11-18-payment-failed.png")
    #expect(name("2026-11-18 payment failed", datePrefix: true) == "2026-11-18-payment-failed.png")
}

@Test func theAppSuffixIsAddedUnlessTheNameHasItAlready() {
    #expect(name("payment failed", appSuffix: true, app: "Google Chrome") == "payment-failed-google-chrome.png")
    #expect(name("safari payment failed", appSuffix: true, app: "Safari") == "safari-payment-failed.png")
    #expect(name("payment failed", appSuffix: true, app: nil) == "payment-failed.png")
}

@Test func aStampReplacesTheDatePrefixAndSurvivesTheWordCut() {
    let result = name("Screenshot Safari", stamp: "2026-11-18-100000", length: .short, datePrefix: true)
    #expect(result == "screenshot-safari-2026-11-18-100000.png")
}

@Test func theOriginalExtensionIsKept() {
    #expect(name("a photo", ext: "HEIC") == "a-photo.HEIC")
    #expect(name("a photo", ext: "") == "a-photo")
}

@Test func anEmptyNameBecomesScreenshot() {
    #expect(name("!!! ///") == "screenshot.png")
}

@Test func aClashGetsTheNextFreeNumber() {
    let taken: Set<String> = ["a.png", "a-2.png"]
    #expect(NameCleaner.resolveClash("a.png") { taken.contains($0) } == "a-3.png")
    #expect(NameCleaner.resolveClash("b.png") { taken.contains($0) } == "b.png")
    #expect(NameCleaner.resolveClash("a") { $0 == "a" } == "a-2")
}
