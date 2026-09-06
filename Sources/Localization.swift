import Foundation

/// Looks a user-facing string up in Localizable.strings, formatting it when arguments are
/// supplied. Keys are dotted and stable, so the English wording can be reworded without
/// touching any call site.
///
/// Log messages deliberately stay in English: they are diagnostics meant to be pasted into
/// a bug report, not interface.
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// Whether the interface reads right to left.
///
/// Not `NSApp.userInterfaceLayoutDirection`. With the bundle resolved to Arabic that still
/// answered left-to-right — measured, with the app running and every string on screen in
/// Arabic — so the rows mirrored nothing. The resolved localization is what decided which
/// strings are showing, so it is what decides which way they run.
///
/// Read once: it cannot change without relaunching, and it is consulted while building
/// every row of the menu.
let interfaceIsRightToLeft: Bool = {
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    return NSLocale.characterDirection(forLanguage: language) == .rightToLeft
}()
