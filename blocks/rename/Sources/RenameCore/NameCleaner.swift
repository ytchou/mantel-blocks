import Foundation

/// Turns raw words into a safe file name. Pure.
///
/// The model does not keep to requested lengths and may return punctuation,
/// so every name goes through here, whichever namer produced it.
enum NameCleaner {
    static let maxLength = 80
    static let emptyName = "screenshot"

    /// Lower-case kebab-case. Letters and digits are kept (CJK as-is); every
    /// other character, including `/`, `:`, dots and control characters,
    /// becomes one hyphen. Apostrophes are dropped so "don't" stays one word.
    /// No leading or trailing hyphen, so no leading dot either.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingHyphen = false
        for character in text.precomposedStringWithCanonicalMapping {
            if character == "'" || character == "\u{2019}" { continue }
            if character.isLetter || character.isNumber {
                if pendingHyphen, !out.isEmpty { out += "-" }
                pendingHyphen = false
                out += character.lowercased()
            } else {
                pendingHyphen = true
            }
        }
        return out
    }

    /// Keep the first `words` hyphen-separated words, then cap at `maxLength`
    /// characters, cutting back to a hyphen when one is past the middle.
    static func cut(_ slug: String, words: Int, maxLength: Int = NameCleaner.maxLength) -> String {
        let kept = slug.split(separator: "-").prefix(max(words, 0)).joined(separator: "-")
        return cap(kept, maxLength: maxLength)
    }

    static func cap(_ slug: String, maxLength: Int = NameCleaner.maxLength) -> String {
        guard slug.count > maxLength else { return slug }
        var cut = String(slug.prefix(max(maxLength, 0)))
        if let hyphen = cut.range(of: "-", options: .backwards),
           cut.distance(from: cut.startIndex, to: hyphen.lowerBound) >= maxLength / 2 {
            cut = String(cut[..<hyphen.lowerBound])
        }
        while cut.hasSuffix("-") { cut.removeLast() }
        return cut
    }

    /// The final file name.
    ///
    /// - Parameters:
    ///   - base: Descriptive words from the model or the fallback.
    ///   - stamp: A date-and-time stamp the fallback adds when it has no title
    ///     words. Appended after the word cut; it already holds the date, so
    ///     no date prefix is added with it.
    ///   - appName: The frontmost app at capture time, for the optional suffix.
    ///   - date: The screenshot's creation date, for the optional prefix.
    ///   - fileExtension: The original extension, kept as-is.
    static func fileName(
        base: String,
        stamp: String? = nil,
        options: NamingOptions,
        appName: String?,
        date: Date,
        timeZone: TimeZone = .current,
        fileExtension: String
    ) -> String {
        var body = cut(slug(base), words: options.length.wordLimit)

        var suffix: [String] = []
        if let stamp, !stamp.isEmpty { suffix.append(stamp) }
        if options.appNameSuffix, let app = appName.map(slug), !app.isEmpty, !containsWords(body, app) {
            suffix.append(app)
        }
        var prefix = ""
        if options.datePrefix, stamp == nil {
            let day = dayString(date, timeZone: timeZone)
            if !body.hasPrefix(day) { prefix = day }
        }

        // Cap the descriptive part first, so the prefix and suffix survive.
        let reserved = (prefix.isEmpty ? 0 : prefix.count + 1) + suffix.reduce(0) { $0 + $1.count + 1 }
        body = cap(body, maxLength: max(maxLength - reserved, 10))
        var name = ([prefix, body] + suffix).filter { !$0.isEmpty }.joined(separator: "-")
        name = cap(name)
        if name.isEmpty { name = emptyName }
        return fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
    }

    /// `yyyy-MM-dd` in `timeZone`.
    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "yyyy-MM-dd", timeZone: timeZone)
    }

    /// `yyyy-MM-dd-HHmmss` in `timeZone`.
    static func stampString(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "yyyy-MM-dd-HHmmss", timeZone: timeZone)
    }

    /// A free name in a folder: `name.ext`, else `name-2.ext`, `name-3.ext`, …
    /// `isTaken` answers for a candidate file name.
    static func resolveClash(_ fileName: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(fileName) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let stem = ext.isEmpty ? fileName : String(fileName.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    private static func containsWords(_ slug: String, _ words: String) -> Bool {
        "-\(slug)-".contains("-\(words)-")
    }

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
