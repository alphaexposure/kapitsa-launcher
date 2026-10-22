import Foundation

/// A discovered Kapitsa executable.
struct KapitsaExecutable: Equatable {
    /// The absolute path to the executable.
    let path: String

    /// A file URL pointing to the executable.
    var url: URL {
        URL(fileURLWithPath: path)
    }
}

/// Searches standard locations for the Kapitsa executable.
///
/// The discovery logic is deliberately kept separate from the SwiftUI layer.
/// The executability check and the home-directory expansion are injectable,
/// which makes the selection behavior unit-testable without depending on a
/// real Kapitsa installation.
struct KapitsaExecutableDiscovery {
    /// Determines whether an absolute path is an existing, executable file.
    private let isExecutable: (String) -> Bool

    /// Expands a leading `~` in a candidate path into the user's home directory.
    private let expandHome: (String) -> String

    /// The standard candidate locations, checked in this order.
    static let defaultCandidatePaths: [String] = [
        "/opt/homebrew/bin/kapitsa",
        "~/.local/bin/kapitsa",
    ]

    /// Expands a leading `~` into the user's home directory.
    static func expandHomePath(_ path: String) -> String {
        guard path.hasPrefix("~/") else {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(String(path.dropFirst(2))).path
    }

    /// A discovery that inspects the real filesystem.
    static let filesystem = KapitsaExecutableDiscovery(
        isExecutable: { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return false
            }
            return FileManager.default.isExecutableFile(atPath: path)
        },
        expandHome: Self.expandHomePath
    )

    init(
        isExecutable: @escaping (String) -> Bool,
        expandHome: @escaping (String) -> String = Self.expandHomePath
    ) {
        self.isExecutable = isExecutable
        self.expandHome = expandHome
    }

    /// Searches the given candidate paths in order and returns the first valid executable.
    func discover(candidatePaths: [String]) -> KapitsaExecutable? {
        for rawPath in candidatePaths {
            let absolutePath = expandHome(rawPath)
            if isExecutable(absolutePath) {
                return KapitsaExecutable(path: absolutePath)
            }
        }
        return nil
    }

    /// Searches the standard candidate locations and returns the first valid executable.
    func discover() -> KapitsaExecutable? {
        discover(candidatePaths: Self.defaultCandidatePaths)
    }
}
