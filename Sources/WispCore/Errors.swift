import Foundation

/// Stable error codes. The negative range mirrors the layout used by the Sky daemon so clients can pattern-match.
public enum WispErrorCode: Int, CaseIterable {
    case senderNotAuthenticated = -10000
    case invalidRequest = -10001
    case unknownMethod = -10002
    case invalidParams = -10003
    case internalError = -10005
    case appNotAllowed = -10006
    case appNotFound = -10007
    case accessibilityError = -10008
    case permissionsNotGranted = -10009
    case invalidApp = -10010
    case noActiveSession = -10011
    case userStoppedSession = -10012
    case incompatibleClientVersion = -10013
    case permissionsPending = -10014
    case blockedURL = -10015
    case userIntervened = -10016
    case ambiguousApp = -10018
    case screenLocked = -10020
    case staleElement = -10021
    case invalidElement = -10022
    case elementOffscreen = -10023
    case actionNotAvailable = -10024
    case windowNotFound = -10025
    case timeout = -10026
    case protocolError = -10027
    case notConnected = -10028
    case secureFieldBlocked = -10029
    case cancelled = -10030
    case chromeUnavailable = -10031
    case tabNotFound = -10032
    case launchFailed = -10033

    public var name: String {
        switch self {
        case .senderNotAuthenticated: return "senderNotAuthenticated"
        case .invalidRequest: return "invalidRequest"
        case .unknownMethod: return "unknownMethod"
        case .invalidParams: return "invalidParams"
        case .internalError: return "internalError"
        case .appNotAllowed: return "appNotAllowed"
        case .appNotFound: return "appNotFound"
        case .accessibilityError: return "accessibilityError"
        case .permissionsNotGranted: return "permissionsNotGranted"
        case .invalidApp: return "invalidApp"
        case .noActiveSession: return "noActiveSession"
        case .userStoppedSession: return "userStoppedSession"
        case .incompatibleClientVersion: return "incompatibleClientVersion"
        case .permissionsPending: return "permissionsPending"
        case .blockedURL: return "blockedURL"
        case .userIntervened: return "userIntervened"
        case .ambiguousApp: return "ambiguousApp"
        case .screenLocked: return "screenLocked"
        case .staleElement: return "staleElement"
        case .invalidElement: return "invalidElement"
        case .elementOffscreen: return "elementOffscreen"
        case .actionNotAvailable: return "actionNotAvailable"
        case .windowNotFound: return "windowNotFound"
        case .timeout: return "timeout"
        case .protocolError: return "protocolError"
        case .notConnected: return "notConnected"
        case .secureFieldBlocked: return "secureFieldBlocked"
        case .cancelled: return "cancelled"
        case .chromeUnavailable: return "chromeUnavailable"
        case .tabNotFound: return "tabNotFound"
        case .launchFailed: return "launchFailed"
        }
    }
}

public struct WispError: Error, CustomStringConvertible {
    public let code: WispErrorCode
    public let message: String
    public let data: JSON?

    public init(_ code: WispErrorCode, _ message: String, data: JSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "\(code.name): \(message)" }

    /// A plain-language sentence for the interruption codes an agent should relay to the user, ending with the code
    /// name in parentheses so the agent can still pattern-match. `nil` for every other error: callers keep their
    /// own `name: message` format for those.
    public var userFacingText: String? { WispError.userFacingText(for: code) }

    public static func userFacingText(for code: WispErrorCode) -> String? {
        switch code {
        case .userIntervened:
            return "Wisp stopped because you took control of the mouse or keyboard. Re-read the state before continuing. (userIntervened)"
        case .userStoppedSession:
            return "Wisp stopped because you pressed Esc or chose Stop in the menu bar. (userStoppedSession)"
        case .screenLocked:
            return "Wisp paused because the screen is locked. (screenLocked)"
        case .cancelled:
            return "The action was cancelled. (cancelled)"
        default:
            return nil
        }
    }

    public var json: JSON {
        var o: [String: JSON] = ["code": .int(code.rawValue), "name": .string(code.name), "message": .string(message)]
        if let d = data { o["data"] = d }
        return .object(o)
    }

    public static func from(json: JSON) -> WispError {
        let code = WispErrorCode(rawValue: json["code"].int ?? WispErrorCode.internalError.rawValue) ?? .internalError
        return WispError(code, json["message"].string ?? "unknown error", data: json["data"].isNull ? nil : json["data"])
    }
}
