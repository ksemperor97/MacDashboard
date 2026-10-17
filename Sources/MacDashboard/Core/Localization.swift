import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ko, en

    var id: String { rawValue }

    /// Shown in both languages so the option can be found whatever the current language is.
    var pickerLabel: String {
        switch self {
        case .system: L.t("시스템 설정 따름", "Follow System")
        case .ko: "한국어"
        case .en: "English"
        }
    }
}

/// Two-language UI strings. Text is resolved when it is displayed, so switching the language in
/// Settings updates everything without re-fetching data.
enum L {
    static var isKorean: Bool {
        switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.language) ?? "") ?? .system {
        case .ko: true
        case .en: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
    }

    static func t(_ ko: String, _ en: String) -> String { isKorean ? ko : en }
}

/// A label kept in both languages (window names, notes) and resolved at display time.
struct Loc: Equatable {
    let ko: String
    let en: String

    init(_ ko: String, _ en: String) {
        self.ko = ko
        self.en = en
    }

    var text: String { L.t(ko, en) }
}
