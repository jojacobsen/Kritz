import Foundation

/// Tiny localization helper. Keys are the English strings themselves, so English needs no
/// table (missing keys fall back to the key). Translations live in
/// `Localization/<lang>.lproj/Localizable.strings`, copied into the app bundle by build-app.sh.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
