import Foundation
import MySQLNIO

/// Sends anonymous, best-effort usage pings to a first-party endpoint
/// (self-hosted on tokay.tr — see `server/analytics/`). Fire-and-forget: a
/// failed, slow, or offline request never blocks or surfaces an error to
/// the UI, and nothing is queued or retried. Respects
/// `AppSettings.General.analyticsOptOut` — when set, no device ID is even
/// generated and no request is made.
@MainActor
enum AnalyticsService {
    private static let endpoint = URL(string: "https://tokay.tr/MySQLClient/analytics/analytics.php")!
    private static let deviceIDDefaultsKey = "analyticsDeviceID"

    static func trackAppOpen() {
        track(event: "app_open")
    }

    static func trackFeatureUsed(_ feature: String) {
        track(event: "feature_used", feature: feature)
    }

    /// Reports only the numeric MySQL/MariaDB error code (e.g. 1062 for a
    /// duplicate-entry error) — never the server's message text, which can
    /// echo back real row data (`Duplicate entry 'someone@example.com' for
    /// key 'PRIMARY'`). Non-`MySQLError`s (e.g. local file I/O failures)
    /// and `MySQLError` cases with no numeric code (`.closed`,
    /// `.protocolError`, …) are silently skipped — there is nothing safe
    /// to send for those without touching free text.
    static func trackError(_ error: Error, feature: String) {
        guard let code = mysqlErrorCode(error) else { return }
        track(event: "error", feature: feature, errorCode: code)
    }

    private static func mysqlErrorCode(_ error: Error) -> Int? {
        guard let mysqlError = error as? MySQLError else { return nil }
        switch mysqlError {
        case .server(let errorPacket):
            return Int(errorPacket.errorCode.rawValue)
        case .duplicateEntry:
            return Int(MySQLProtocol.ErrorCode.DUP_ENTRY.rawValue)
        case .invalidSyntax:
            return Int(MySQLProtocol.ErrorCode.PARSE_ERROR.rawValue)
        default:
            return nil
        }
    }

    private static func track(event: String, feature: String? = nil, errorCode: Int? = nil) {
        guard !SettingsStore.shared.settings.general.analyticsOptOut, !isRunningTests else { return }

        let payload = Payload(
            deviceID: deviceID(),
            event: event,
            feature: feature,
            errorCode: errorCode,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel,
            language: Bundle.main.preferredLocalizations.first ?? "en",
            timezone: TimeZone.current.identifier,
            appearance: AppearanceMode.current.rawValue
        )

        let url = endpoint
        Task.detached(priority: .background) {
            guard let body = try? JSONEncoder().encode(payload) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Test runs exercise the same code paths as real use (a backup ends in
    /// `trackFeatureUsed("db_backup")`), and must not count as usage.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    private static func deviceID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIDDefaultsKey)
        return generated
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Deliberately not `operatingSystemVersionString` — that string is
    /// localized (e.g. "Version"/"Build" translated) by the app's own
    /// language override, which both varies per language and runs longer
    /// than the plain number. This is locale-independent and short.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// e.g. "MacBookPro18,3" — via `sysctlbyname`, the standard way to read
    /// the Mac model identifier; Foundation has no typed API for this.
    static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        if let nullIndex = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(nullIndex...)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private struct Payload: Encodable {
        let deviceID: String
        let event: String
        let feature: String?
        let errorCode: Int?
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let language: String
        let timezone: String
        /// "light" or "dark" — this app has no "follow system" option
        /// (`AppearanceMode` is just the two cases), so this is always one
        /// of the two, never ambiguous.
        let appearance: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case event
            case feature
            case errorCode = "error_code"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case deviceModel = "device_model"
            case language
            case timezone
            case appearance
        }
    }
}
