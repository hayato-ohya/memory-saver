import Foundation
import Testing
@testable import MemorySaverCore

@Suite struct TranslationFileTests {
    private let translations = Translations.shared

    @Test func japaneseAndEnglishAreAvailable() {
        #expect(AppLanguage.available.contains(.japanese))
        #expect(AppLanguage.available.contains(.english))
    }

    @Test func everyKeyIsTranslatedInEveryLanguage() {
        for language in AppLanguage.available {
            for key in L10nKey.allCases {
                let format = translations.format(for: key.rawValue, language: language)
                #expect(format != nil, "\(language.identifier) has no entry for \(key.rawValue)")
                #expect(format?.isEmpty == false, "\(language.identifier) has an empty entry for \(key.rawValue)")
            }
        }
    }

    /// A translation that drops or adds an argument would crash or print garbage at run time.
    @Test func everyLanguageTakesTheSameArgumentsAsEnglish() throws {
        for key in L10nKey.allCases {
            let reference = try #require(arguments(of: key, in: .english))
            for language in AppLanguage.available {
                #expect(
                    arguments(of: key, in: language) == reference,
                    "\(language.identifier) and en disagree on the arguments of \(key.rawValue)")
            }
        }
    }

    /// No file may carry entries the code no longer uses.
    @Test func noFileHasKeysTheCodeDoesNotKnow() throws {
        let known = Set(L10nKey.allCases.map(\.rawValue))
        for language in AppLanguage.available {
            let folder = try #require(Bundle.module.url(forResource: language.identifier, withExtension: "lproj"))
            for file in ["Localizable.strings", "Localizable.stringsdict"] {
                guard let entries = NSDictionary(contentsOf: folder.appendingPathComponent(file)) else { continue }
                let unknown = Set(entries.allKeys.compactMap { $0 as? String }).subtracting(known)
                #expect(unknown.isEmpty, "\(language.identifier)/\(file) has unused keys: \(unknown.sorted())")
            }
        }
    }

    /// The argument types a format takes, ordered by position: "%2$@ has %1$d" → ["d", "@"].
    private func arguments(of key: L10nKey, in language: AppLanguage) -> [String]? {
        guard let format = translations.format(for: key.rawValue, language: language) else { return nil }
        // Plural entries resolve to their real format only once formatted, and every plural
        // entry takes exactly the count.
        if format.contains("%#@") { return ["d"] }
        let specifier = /%(?:(\d+)\$)?(?:ll|l)?([@dfs])/
        var positional: [Int: String] = [:]
        var sequential: [String] = []
        for match in format.replacingOccurrences(of: "%%", with: "").matches(of: specifier) {
            if let position = match.1.flatMap({ Int($0) }) {
                positional[position] = String(match.2)
            } else {
                sequential.append(String(match.2))
            }
        }
        return positional.isEmpty ? sequential : positional.keys.sorted().map { positional[$0]! }
    }
}

@Suite struct TranslationLookupTests {
    @Test func looksUpTheCurrentLanguage() {
        AppLanguage.$override.withValue(.japanese) { #expect(tr(.relaunchButton) == "再起動") }
        AppLanguage.$override.withValue(.english) { #expect(tr(.relaunchButton) == "Relaunch") }
    }

    @Test func pluralsFollowTheLanguage() {
        AppLanguage.$override.withValue(.english) {
            #expect(tr(.popoverRankingProcessCount, 1) == "1 process")
            #expect(tr(.popoverRankingProcessCount, 16) == "16 processes")
        }
        AppLanguage.$override.withValue(.japanese) {
            #expect(tr(.popoverRankingProcessCount, 1) == "1 プロセス")
            #expect(tr(.popoverRankingProcessCount, 16) == "16 プロセス")
        }
    }

    @Test func aLanguageWithoutTranslationsFallsBackToEnglish() {
        AppLanguage.$override.withValue(AppLanguage(identifier: "fr")) {
            #expect(tr(.relaunchButton) == "Relaunch")
        }
    }
}

@Suite struct LanguageResolutionTests {
    private let available = [AppLanguage.english, .japanese, AppLanguage(identifier: "zh-Hans")]

    private func resolve(_ preferred: String...) -> String {
        AppLanguage.resolve(preferredLanguages: preferred, available: available).identifier
    }

    @Test func picksTheFirstPreferredLanguageWithATranslation() {
        #expect(resolve("ja-JP", "en-US") == "ja")
        #expect(resolve("en-US", "ja-JP") == "en")
        #expect(resolve("fr-FR", "ja-JP") == "ja")
    }

    @Test func matchesScriptVariants() {
        #expect(resolve("zh-Hans-CN") == "zh-Hans")
        // No folder for Traditional Chinese or bare "zh": move on to the next preference.
        #expect(resolve("zh-Hant-TW", "ja-JP") == "ja")
    }

    @Test func fallsBackToEnglish() {
        #expect(resolve("fr-FR", "de") == "en")
        #expect(resolve() == "en")
    }
}
