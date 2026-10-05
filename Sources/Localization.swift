import Foundation

/// AppKit follows the user's preferred macOS language; English is the fallback.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
