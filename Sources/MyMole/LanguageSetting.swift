import Foundation

/// The language MyMole shows, chosen in Settings: the Mac's own, or one of
/// the languages the app carries. It is the app's own `AppleLanguages`, the
/// same setting as the per-app language in System Settings, so macOS reads
/// it when MyMole starts and the choice applies from the next launch.
enum LanguageSetting {
    static let key = "AppleLanguages"

    /// The languages the app carries, as their codes, English first.
    static var available: [String] {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        return codes.sorted { a, b in
            a == "en" ? true : b == "en" ? false : name(of: a).localizedCompare(name(of: b)) == .orderedAscending
        }
    }

    /// A language named in itself, such as "Français" or "Deutsch".
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The language chosen for MyMole, or nil when it follows the Mac: read
    /// from the app's own settings, not the Mac's.
    static func chosen(
        in own: [String: Any]? = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
    ) -> String? {
        (own?[key] as? [String])?.first
    }

    /// Sets MyMole's language, or lets it follow the Mac again with nil.
    static func choose(_ code: String?, store: ([String]?) -> Void = store) {
        store(code.map { [$0] })
    }

    private static func store(_ languages: [String]?) {
        if let languages { UserDefaults.standard.set(languages, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
