import BlockKit
import Foundation

/// How many words a name keeps. The model ignores requested lengths
/// (`spikes/FINDINGS.md`, table C), so the cut happens in `NameCleaner`.
enum NameLength: String, CaseIterable, Sendable {
    case short
    case standard
    case long

    var wordLimit: Int {
        switch self {
        case .short: 3
        case .standard: 5
        case .long: 8
        }
    }

    var title: String {
        switch self {
        case .short: "Short"
        case .standard: "Standard"
        case .long: "Long"
        }
    }
}

/// Language of generated names. Chinese screenshots get English names unless
/// the model is told otherwise (`spikes/FINDINGS.md`, table C).
enum NameLanguage: String, CaseIterable, Sendable {
    case matchContent
    case english
    case traditionalChinese

    var title: String {
        switch self {
        case .matchContent: "Match content"
        case .english: "English"
        case .traditionalChinese: "Traditional Chinese"
        }
    }
}

/// The settings one naming job uses, copied when the job starts.
struct NamingOptions: Sendable, Equatable {
    var length: NameLength = .standard
    var language: NameLanguage = .matchContent
    var datePrefix = false
    var appNameSuffix = false
}

/// The block's settings, as declared in `manifest.json`. The app stores them
/// as `rename.<key>`, the keys the in-app block used, so stored values carry over.
enum RenameSettings {
    enum Key {
        static let length = "nameLength"
        static let language = "nameLanguage"
        static let datePrefix = "datePrefix"
        static let appNameSuffix = "appNameSuffix"
        /// The note that says whether the on-device model is ready.
        static let modelStatus = "modelStatus"
    }

    /// The options from the values the app sent; a missing or unknown value
    /// takes the default.
    static func options(from settings: [String: SettingValue]) -> NamingOptions {
        NamingOptions(
            length: settings[Key.length]?.string.flatMap(NameLength.init(rawValue:)) ?? .standard,
            language: settings[Key.language]?.string.flatMap(NameLanguage.init(rawValue:)) ?? .matchContent,
            datePrefix: settings[Key.datePrefix]?.bool ?? false,
            appNameSuffix: settings[Key.appNameSuffix]?.bool ?? false
        )
    }
}
