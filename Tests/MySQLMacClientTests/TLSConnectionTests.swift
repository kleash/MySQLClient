import XCTest
import MySQLNIO
import NIOSSL
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

    /// Asking for encryption must end in either a connection that really is
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
            // MySQL 8.4 has no have_ssl, and has TLS on unless it's switched
            // off: only DISABLED excuses the refusal.
            XCTAssertEqual(hasTLS, "DISABLED", "refused although the server offers TLS")
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

    /// The refusal has to come before the login: once the login is out, a
    /// network attacker who removed TLS from the greeting has the password,
    /// or what it takes to guess it. A wrong password tells: "access
    /// denied" means the server got the login.
    func testRequiredEncryptionIsRefusedBeforeTheLoginGoesOut() async throws {
        let probe = MySQLService()
        try await probe.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username, password: TestDatabase.password, database: nil)
        let hasTLS = try await probe.textQuery("SHOW GLOBAL VARIABLES LIKE 'have_ssl'").first?.column("Value")?.string
        try await probe.disconnect()
        try XCTSkipUnless(hasTLS == "DISABLED", "the server offers TLS")
        for mode in [TLSMode.required, .verifyCertificate] {
            let service = MySQLService()
            do {
                try await service.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                                          password: "wrong-\(UUID().uuidString)", database: nil, tls: mode)
                XCTFail("\(mode): connected")
                try await service.disconnect()
            } catch MySQLServiceError.notEncrypted {
                // Refused before the login.
            }
        }
    }

    /// Verifying refuses a certificate this Mac doesn't trust, such as a
    /// server in the middle would show; encrypting without verifying takes
    /// it, and gets as far as the login.
    func testOnlyVerifyingRefusesAnUntrustedCertificate() async throws {
        let port = try await startFakeServer().server.localAddress!.port!
        let unverified = await loginOutcome(.required, port: port)
        XCTAssertTrue(unverified.contains(fakeServerRefusal), unverified)
        let verified = await loginOutcome(.verifyCertificate, port: port)
        XCTAssertTrue(verified.contains("CERTIFICATE_VERIFY_FAILED"), verified)
    }

    /// Verifying refuses a trusted certificate made out to another host.
    /// A test can't make this Mac trust a certificate, so this one takes
    /// the TLS settings the app uses for verifyCertificate and trusts the
    /// fake server's certificate in them.
    func testVerifyingRefusesACertificateForAnotherHost() async throws {
        let (server, certificates) = try await startFakeServer()
        var configuration = MySQLService.tlsConfiguration(.verifyCertificate)
        configuration.trustRoots = .certificates(certificates)
        for (name, expected) in [("localhost", fakeServerRefusal), ("db.example.com", "failedToValidateHostname")] {
            let outcome: String
            do {
                _ = try await MySQLConnection.connect(
                    to: server.localAddress!, username: "root", database: "", tlsConfiguration: configuration,
                    serverHostname: name, on: MultiThreadedEventLoopGroup.singleton.next()
                ).get()
                outcome = "logged in"
            } catch {
                outcome = String(describing: error)
            }
            XCTAssertTrue(outcome.contains(expected), "\(name): \(outcome)")
        }
    }

    /// TLS 1.0 and 1.1 are broken (RFC 8996): an encrypted connection
    /// refuses them, even when the server has nothing newer.
    func testEncryptionRefusesTLSOlderThan1_2() async throws {
        let port = try await startFakeServer(maximumTLSVersion: .tlsv11).server.localAddress!.port!
        let outcome = await loginOutcome(.required, port: port)
        // The client offers nothing older than 1.2, so the server has no
        // version in common with it.
        XCTAssertTrue(outcome.contains("ALERT_PROTOCOL_VERSION"), outcome)
    }

    /// How logging in to the fake server ends: it never lets anyone in.
    private func loginOutcome(_ tls: TLSMode, port: Int) async -> String {
        do {
            try await MySQLService().connect(host: "127.0.0.1", port: port, username: "root", password: nil, database: nil, tls: tls)
            return "logged in"
        } catch {
            return String(describing: error)
        }
    }

    /// A `FakeMySQLServer` on 127.0.0.1 with a certificate for `localhost`
    /// that /usr/bin/openssl makes just now. It stops when the test ends.
    private func startFakeServer(maximumTLSVersion: TLSVersion? = nil) async throws -> (server: Channel, certificates: [NIOSSLCertificate]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyPath = directory.appendingPathComponent("key.pem").path
        let certificatePath = directory.appendingPathComponent("certificate.pem").path
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost", "-keyout", keyPath, "-out", certificatePath,
        ]
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()

        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: keyPath, format: .pem))
        )
        configuration.maximumTLSVersion = maximumTLSVersion
        let tls = try NIOSSLContext(configuration: configuration)
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(FakeMySQLServer(tls: tls))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await server.close() }
        return (server, certificates)
    }
}

private let fakeServerRefusal = "TLS is up, but no logins here"

/// Just enough of a MySQL server to see how far a client's TLS gets: its
/// greeting offers TLS, it switches to TLS when the client asks, and then
/// it turns the login down with `fakeServerRefusal`.
private final class FakeMySQLServer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let tls: NIOSSLContext
    private var received = ByteBuffer()
    private var encrypted = false

    init(tls: NIOSSLContext) {
        self.tls = tls
    }

    func channelActive(context: ChannelHandlerContext) {
        var greeting: [UInt8] = [10] + Array("8.4.0\0".utf8)        // HandshakeV10, server version
        greeting += [1, 0, 0, 0] + Array("abcdefgh\0".utf8)         // connection ID, auth data, filler
        // Capabilities LONG_PASSWORD, PROTOCOL_41, SSL, SECURE_CONNECTION
        // and PLUGIN_AUTH; character set, status, auth data length.
        greeting += [0x01, 0x8a, 0x21, 0x02, 0x00, 0x08, 0x00, 21] + [UInt8](repeating: 0, count: 10)
        greeting += Array("ijklmnopqrst\0mysql_native_password\0".utf8)
        context.writeAndFlush(wrapOutboundOut(Self.packet(0, greeting)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if encrypted {
            // The login, decrypted: ERR 1045.
            let refusal = [0xff, 0x15, 0x04] + Array("#28000\(fakeServerRefusal)".utf8)
            context.writeAndFlush(wrapOutboundOut(Self.packet(3, refusal)), promise: nil)
            return
        }
        var bytes = unwrapInboundIn(data)
        received.writeBuffer(&bytes)
        // The client's SSLRequest: a 4-byte header and 32 bytes.
        guard received.readableBytes >= 36 else { return }
        received.moveReaderIndex(forwardBy: 36)
        encrypted = true
        do {
            try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first)
        } catch {
            return context.close(promise: nil)
        }
        // Whatever came with it is the start of the client's TLS handshake.
        if received.readableBytes > 0 {
            context.pipeline.syncOperations.fireChannelRead(NIOAny(received))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// A MySQL packet: 3-byte length, sequence number, payload.
    private static func packet(_ sequence: UInt8, _ payload: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(payload.count) | UInt32(sequence) << 24, endianness: .little)
        buffer.writeBytes(payload)
        return buffer
    }
}
