import Foundation

/// Single source of truth for the version. `scripts/set-version.sh` rewrites this file at release time.
public enum WispVersion {
    public static let string = "0.2.0"
    public static let build = "1"
}
