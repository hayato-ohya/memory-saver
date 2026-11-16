import Foundation

// The app's text lives in translation files, one folder per language:
//   Sources/MemorySaverCore/Resources/<language>.lproj/Localizable.strings      plain strings
//   Sources/MemorySaverCore/Resources/<language>.lproj/Localizable.stringsdict  strings with plurals
// To add a language, copy `en.lproj` to `<language>.lproj` and translate the values. Nothing
// in the code lists the languages: they are discovered from the folders.

/// A language the app has a translation folder for, named as the folder is ("ja", "en", "zh-Hans").
public struct AppLanguage: Hashable, Sendable {
    public let identifier: String

    public init(identifier: String) { self.identifier = identifier }

    public static let japanese = AppLanguage(identifier: "ja")
    public static let english = AppLanguage(identifier: "en")

    /// Used when none of the user's languages has a translation, and for any string a
    /// translation is missing.
    public static let fallback = english

    /// Every language with a translation folder, sorted by identifier.
    public static var available: [AppLanguage] { Translations.shared.languages }

    /// Set for the duration of a task to force a language, so tests do not depend on the
    /// machine's language settings.
    @TaskLocal public static var override: AppLanguage?

    public static var current: AppLanguage { override ?? system }

    /// The language the user asked for. Fixed for the life of the process, like any Mac app:
    /// a change in System Settings applies on the next launch.
    private static let system: AppLanguage = {
        // For rendering the UI in a given language from a test or a debug run.
        if let forced = ProcessInfo.processInfo.environment["MEMORYSAVER_LANGUAGE"] {
            let language = AppLanguage(identifier: forced)
            if available.contains(language) { return language }
        }
        // Includes the per-app language chosen in System Settings and `-AppleLanguages`.
        return resolve(preferredLanguages: Locale.preferredLanguages, available: available)
    }()

    /// The first preferred language that has a translation. A regional or script variant
    /// matches its own folder first ("zh-Hant-TW" → "zh-Hant"), then the bare language ("zh").
    public static func resolve(preferredLanguages: [String], available: [AppLanguage]) -> AppLanguage {
        let folders = Dictionary(
            available.map { ($0.identifier.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for preferred in preferredLanguages {
            let language = Locale(identifier: preferred).language
            guard let code = language.languageCode?.identifier.lowercased() else { continue }
            var candidates = [preferred.replacingOccurrences(of: "_", with: "-").lowercased()]
            if let script = language.script?.identifier.lowercased() { candidates.append("\(code)-\(script)") }
            candidates.append(code)
            if let match = candidates.lazy.compactMap({ folders[$0] }).first { return match }
        }
        return fallback
    }
}

/// The text for `key` in the current language, with `arguments` substituted into its format
/// specifiers (`%@`, `%d`, and `%1$@`-style positions where a translation reorders them).
public func tr(_ key: L10nKey, _ arguments: any CVarArg...) -> String {
    Translations.shared.string(for: key.rawValue, language: AppLanguage.current, arguments: arguments)
}

/// Reads the translation folders out of the resource bundle.
final class Translations: Sendable {
    static let shared = Translations(bundle: .module)

    let languages: [AppLanguage]
    /// One bundle per `<language>.lproj` folder; looking a key up in it reads that language only.
    private let tables: [AppLanguage: Bundle]

    init(bundle: Bundle) {
        var tables: [AppLanguage: Bundle] = [:]
        for url in bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil) ?? [] {
            if let table = Bundle(url: url) {
                tables[AppLanguage(identifier: url.deletingPathExtension().lastPathComponent)] = table
            }
        }
        self.tables = tables
        self.languages = tables.keys.sorted { $0.identifier < $1.identifier }
    }

    func string(for key: String, language: AppLanguage, arguments: [any CVarArg] = []) -> String {
        // A missing translation shows the fallback language rather than a blank or a raw key.
        for candidate in [language, .fallback] {
            guard let format = format(for: key, language: candidate) else { continue }
            // Formatted even without arguments, so that a literal percent sign is written
            // `%%` in every entry. The locale selects the plural form for `.stringsdict` entries.
            return String(format: format, locale: Locale(identifier: candidate.identifier), arguments: arguments)
        }
        return key
    }

    /// nil when `language` has no entry for `key`.
    func format(for key: String, language: AppLanguage) -> String? {
        guard let table = tables[language] else { return nil }
        let missing = "\u{0}missing"
        let value = table.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }
}
