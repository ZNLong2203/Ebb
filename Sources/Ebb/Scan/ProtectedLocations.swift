import Foundation

/// Folders macOS guards with a privacy prompt (or refuses outright) unless the app has Full Disk Access.
///
/// Reading one of them blocks until the user answers a dialog, so without Full Disk Access Ebb
/// skips them up front and says so, instead of stalling behind a stream of permission prompts.
struct ProtectedLocations: Sendable {
    private static let relativePaths = [
        "Desktop", "Documents", "Downloads",
        "Pictures/Photos Library.photoslibrary", "Music/Music", "Movies/TV",
        "Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Mail", "Library/Safari", "Library/Messages", "Library/Calendars", "Library/Reminders",
        "Library/HomeKit", "Library/Cookies", "Library/Suggestions", "Library/Biome", "Library/Accounts",
        "Library/IdentityServices", "Library/Sharing", "Library/Metadata/CoreSpotlight",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/MobileSync", "Library/Application Support/com.apple.TCC",
        "Library/Application Support/Knowledge", ".Trash",
    ]

    let paths: Set<String>

    static let none = ProtectedLocations(paths: [])

    static func forCurrentUser(hasFullDiskAccess: Bool) -> ProtectedLocations {
        guard !hasFullDiskAccess else { return .none }
        let home = NSHomeDirectory()
        return ProtectedLocations(paths: Set(relativePaths.map { home + "/" + $0 }))
    }

    /// Only locations strictly inside `root`: a folder the user picked explicitly is never skipped.
    func within(_ root: String) -> ProtectedLocations {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return ProtectedLocations(paths: paths.filter { $0.hasPrefix(prefix) })
    }

    /// Exact match, cheap enough to ask for every directory during a scan.
    func isProtected(_ path: String) -> Bool { paths.contains(path) }

    /// The path or any folder above it is protected.
    func covers(_ path: String) -> Bool {
        paths.contains(path) || paths.contains { path.hasPrefix($0 + "/") }
    }
}
