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
