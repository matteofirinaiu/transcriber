import Foundation

/// Version numbers like "1.2.0", as in the app and in the GitHub release tags ("v1.2.0").
public enum AppVersion {
    /// "v1.2.0", or the release page ".../releases/tag/v1.2.0" → "1.2.0". `nil` if it isn't a version.
    public static func fromReleaseTag(_ tag: String) -> String? {
        let name = tag.split(separator: "/").last.map(String.init) ?? tag
        let version = name.hasPrefix("v") ? String(name.dropFirst()) : name
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return version
    }

    /// Compares number by number, so "1.10.0" is newer than "1.9.9" and "1.2" equals "1.2.0".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = numbers(candidate)
        let old = numbers(current)
        for index in 0..<max(new.count, old.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
