//
//  Localization.swift
//  PRTS
//

import Foundation

enum SpeechLanguage: String, CaseIterable, Identifiable, Hashable {
    case english = "English"
    case chinese = "Chinese"

    var id: String { rawValue }

    /// The locale used by AVSpeechSynthesizer and SwiftUI's Locale environment.
    var localeIdentifier: String {
        switch self {
        case .english:
            return "en-US"
        case .chinese:
            return "zh-CN"
        }
    }

    /// The localization folder generated from the String Catalog.
    var resourceIdentifier: String {
        switch self {
        case .english:
            return "en"
        case .chinese:
            return "zh-Hans"
        }
    }

    var displayNameLocalizationKey: String {
        switch self {
        case .english:
            return "settings.language.name.english"
        case .chinese:
            return "settings.language.name.chinese"
        }
    }

    var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    static func fromSystemLanguage() -> SpeechLanguage {
        let preferredLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier
        let languageCode = Locale(identifier: preferredLanguage)
            .language.languageCode?.identifier.lowercased()

        return languageCode == "zh" ? .chinese : .english
    }
}

enum AppLocalization {
    static func bundle(for language: SpeechLanguage) -> Bundle {
        guard let path = Bundle.main.path(
            forResource: language.resourceIdentifier,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            return Bundle.main
        }

        return bundle
    }

    static func string(_ key: String, language: SpeechLanguage) -> String {
        bundle(for: language).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    static func string(
        _ key: String,
        language: SpeechLanguage,
        arguments: [CVarArg]
    ) -> String {
        let template = string(key, language: language)

        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: arguments)
    }
}
