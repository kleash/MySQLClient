import XCTest
@testable import MySQLMacClient

final class TLSConnectionTests: XCTestCase {
    /// Connections saved before encryption could be chosen have no
    /// `tlsMode` key, and must still load (unencrypted, as they were).
    func testConnectionSavedBeforeEncryptionExistedStillLoads() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","host":"db","port":3306,"username":"u"}"#
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(saved.utf8))
        XCTAssertNil(profile.tlsMode)

        var encrypted = profile
        encrypted.tlsMode = .verifyCertificate
        let reloaded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(encrypted))
        XCTAssertEqual(reloaded.tlsMode, .verifyCertificate)
    }

    /// MySQLNIO quietly stays unencrypted when the server has no TLS, so
    /// asking for it must end in either a connection that really is
    /// encrypted or a refusal — never a plain one.
    func testRequiredEncryptionIsOnOrTheConnectionIsRefused() async throws {
        let service = MySQLService()
        do {
            try await service.connect(
                host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                password: TestDatabase.password, database: nil, tls: .required
            )
        } catch MySQLServiceError.notEncrypted {
            let probe = MySQLService()
            try await probe.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: nil)
            let hasTLS = try await probe.textQuery("SHOW GLOBAL VARIABLES LIKE 'have_ssl'").first?.column("Value")?.string
            try await probe.disconnect()
            XCTAssertNotEqual(hasTLS, "YES", "refused although the server offers TLS")
            return
        }
        let cipher = try await service.textQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.column("Value")?.string
        XCTAssertFalse(cipher?.isEmpty ?? true)
        // The connection a restore runs on is encrypted too.
        let separate = try await service.openSeparateConnection()
        let separateCipher = try await separate.textQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.column("Value")?.string
        XCTAssertFalse(separateCipher?.isEmpty ?? true)
        try await separate.disconnect()
        try await service.disconnect()
    }
}
