import XCTest
@testable import MySQLMacClient

/// mysqldump/mariadb-dump and mysql/mariadb as the backup and restore
/// engine: the arguments they get, worked out without a server, then the
/// installed tools against the `TestDatabase` server (skipped when none is
/// installed).
final class ExternalToolTests: XCTestCase {
    // MARK: - Arguments

    /// Lines of the tools' own `--help` (MySQL 9.6 and MariaDB 11.4,
    /// abridged): the options are taken from there, not from the version.
    private let mysqldump = ExternalTool(
        url: URL(fileURLWithPath: "/opt/homebrew/opt/mysql-client/bin/mysqldump"),
        help: """
            --no-login-paths        Don't read login paths from the login path file.
              -y, --no-tablespaces
              --column-statistics Add an ANALYZE TABLE statement to regenerate any existing
              -E, --events        Dump events.
              --hex-blob          Dump binary strings (BINARY, VARBINARY, BLOB) in
              -l, --lock-tables   Lock all tables for read.
              -R, --routines      Dump stored routines (functions and procedures).
              --set-gtid-purged[=name]
              --single-transaction
              --ssl-mode=name     SSL connection mode.
              --ssl-ca=name       CA file in PEM format.
              --triggers          Dump triggers for each dumped table.
              -v, --verbose       Print info about the various stages.
            """
    )

    private let mariadbDump = ExternalTool(
        url: URL(fileURLWithPath: "/opt/homebrew/bin/mariadb-dump"),
        help: """
              -y, --no-tablespaces
              -E, --events        Dump events.
              --hex-blob          Dump binary strings (BINARY, VARBINARY, BLOB) in
              -R, --routines      Dump stored routines (functions and procedures).
              --single-transaction
              --ssl               Enable SSL for connection (automatically enabled with
              --ssl-ca=name       CA file in PEM format (check OpenSSL docs, implies
              --ssl-verify-server-cert
              --triggers          Dump triggers for each dumped table.
            """
    )

    private let mysql = ExternalTool(
        url: URL(fileURLWithPath: "/opt/homebrew/opt/mysql-client/bin/mysql"),
        help: """
              --binary-mode       By default, ASCII '\\0' is disallowed and '\\r\\n' is
              -c, --comments      Preserve comments. Send comments to the server. The
              -f, --force         Continue even if we get an SQL error.
              --max-allowed-packet=#
              --ssl-mode=name     SSL connection mode.
            """
    )

    private let mariadb = ExternalTool(
        url: URL(fileURLWithPath: "/opt/homebrew/bin/mariadb"),
        help: """
              --binary-mode       Binary mode allows certain character sequences to be
              -c, --comments      Preserve comments. Send comments to the server. The
              -f, --force         Continue even if we get an SQL error. Sets
              --print-query-on-error
                                  Print the query if there was an error. Is only enabled in
              --ssl               Enable SSL for connection (automatically enabled with
              --ssl-verify-server-cert
            """
    )

    private func connection(tls: TLSMode? = nil, serverName: String? = nil) -> ExternalTool.Connection {
        ExternalTool.Connection(host: "db.example.com", port: 3307, username: "backup", tls: tls, serverName: serverName,
                                optionFile: ExternalTool.optionFile(password: "s3cret"))
    }

    func testDumpReadsOneSnapshotWithoutLockingAndKeepsEveryObject() throws {
        let arguments = try mysqldump.dumpArguments(database: "shop", connection: connection())

        for option in ["--single-transaction", "--skip-lock-tables", "--routines", "--events", "--triggers", "--hex-blob",
                       "--default-character-set=utf8mb4", "--set-gtid-purged=OFF", "--no-tablespaces", "--column-statistics=0",
                       "--no-login-paths", "--protocol=TCP", "--host=db.example.com", "--port=3307", "--user=backup"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        XCTAssertFalse(arguments.contains("--lock-tables"))
        // A database named like an option is still read as a name.
        XCTAssertEqual(arguments.suffix(3), ["--databases", "--", "shop"])
        XCTAssertFalse(arguments.contains { $0.contains("s3cret") || $0.hasPrefix("--password") || $0.hasPrefix("-p") })
    }

    func testOptionsTheToolDoesNotListAreLeftOut() throws {
        let arguments = try mariadbDump.dumpArguments(database: "shop", connection: connection())

        XCTAssertTrue(arguments.contains("--no-tablespaces"))
        XCTAssertTrue(arguments.contains("--single-transaction"))
        for option in ["--set-gtid-purged=OFF", "--column-statistics=0", "--no-login-paths"] {
            XCTAssertFalse(arguments.contains(option), option)
        }
    }

    func testRestoreSendsTheFileByteForByteWithItsComments() throws {
        let arguments = try mysql.restoreArguments(database: "shop", stopOnError: true, connection: connection())
        for option in ["--binary-mode", "--comments", "--default-character-set=utf8mb4", "--database=shop"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        XCTAssertTrue(arguments.contains { $0.hasPrefix("--max-allowed-packet=") })
        XCTAssertFalse(arguments.contains("--force"))

        let carryingOn = try mysql.restoreArguments(database: nil, stopOnError: false, connection: connection())
        XCTAssertTrue(carryingOn.contains("--force"))
        XCTAssertFalse(carryingOn.contains { $0.hasPrefix("--database") }, "the file's own USE decides")

        // MariaDB's client writes out each failed statement before its error.
        XCTAssertTrue(try mariadb.restoreArguments(database: "shop", stopOnError: false, connection: connection()).contains("--skip-print-query-on-error"))
        XCTAssertFalse(carryingOn.contains("--skip-print-query-on-error"), "MySQL's client has no such option")
    }

    func testEncryptionCarriesOverOrIsRefused() throws {
        XCTAssertFalse(try mysqldump.dumpArguments(database: "shop", connection: connection()).contains { $0.hasPrefix("--ssl") })
        XCTAssertTrue(try mysqldump.dumpArguments(database: "shop", connection: connection(tls: .required)).contains("--ssl-mode=REQUIRED"))
        let verified = try mysqldump.dumpArguments(database: "shop", connection: connection(tls: .verifyCertificate))
        XCTAssertTrue(verified.contains("--ssl-mode=VERIFY_IDENTITY"))
        XCTAssertTrue(verified.contains { $0.hasPrefix("--ssl-ca=") }, "MySQL's client checks a certificate only against a CA file it's given")

        // MariaDB's --ssl alone falls back to an unencrypted connection; only
        // with the certificate checked does it refuse a server without TLS.
        for tls in [TLSMode.required, .verifyCertificate] {
            let arguments = try mariadbDump.dumpArguments(database: "shop", connection: connection(tls: tls))
            XCTAssertTrue(arguments.contains("--ssl") && arguments.contains("--ssl-verify-server-cert"), "\(tls)")
            XCTAssertFalse(arguments.contains("--skip-ssl-verify-server-cert"), "\(tls)")
        }
        // From 11.4 it checks a certificate unless told not to, and so refuses
        // a server without TLS.
        XCTAssertTrue(try mariadbDump.dumpArguments(database: "shop", connection: connection()).contains("--skip-ssl-verify-server-cert"))

        // Through a tunnel the tool would check the certificate against 127.0.0.1.
        XCTAssertThrowsError(try mysqldump.dumpArguments(database: "shop", connection: connection(tls: .verifyCertificate, serverName: "db.example.com")))
        let noTLSOptions = ExternalTool(url: mysql.url, help: "  --force")
        XCTAssertThrowsError(try noTLSOptions.restoreArguments(database: nil, stopOnError: true, connection: connection(tls: .required)))
    }

    /// The option file's own quoting (MySQL's and MariaDB's `my_default`):
    /// inside double quotes `#` isn't a comment and spaces are kept, and a
    /// backslash escapes `"`, `\` and line breaks.
    func testOptionFileQuotesThePassword() {
        XCTAssertEqual(ExternalTool.optionFile(password: " a\"b\\c#d'e=f é\n\\"), "[client]\npassword=\" a\\\"b\\\\c#d'e=f é\\n\\\\\"\n")
        XCTAssertEqual(ExternalTool.optionFile(password: nil), "[client]\n")
        XCTAssertEqual(ExternalTool.optionFile(password: ""), "[client]\n")
    }

    // MARK: - Installed tools

    private func installedTool(_ kind: ExternalTool.Kind) async throws -> ExternalTool {
        guard ExternalTool.locate(kind, configuredPath: "", preferMariaDB: true) != nil else {
            throw XCTSkip("No MySQL or MariaDB command-line tools are installed.")
        }
        return try await ExternalTool.find(kind, configuredPath: "", preferMariaDB: true)
    }

    /// The tool's output, from `--execute`.
    private func execute(_ sql: String, with tool: ExternalTool, _ connection: ExternalTool.Connection) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        _ = try await tool.run(try tool.connectionArguments(connection) + ["--batch", "--skip-column-names", "--execute=\(sql)"],
                               optionFile: connection.optionFile, output: output)
        try output.close()
        return try String(contentsOf: outputURL, encoding: .utf8)
    }

    /// Asked to encrypt, the tool either really is encrypted or refuses: the
    /// MariaDB 10.4 test server has no TLS, so there it must refuse.
    func testRequiredEncryptionIsOnOrTheToolRefuses() async throws {
        let tool = try await installedTool(.client)
        let encrypted = ExternalTool.Connection(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                                                tls: .required, serverName: nil, optionFile: ExternalTool.optionFile(password: TestDatabase.password))
        do {
            let cipher = try await execute("SHOW SESSION STATUS LIKE 'Ssl_cipher'", with: tool, encrypted)
            XCTAssertFalse(cipher.trimmingCharacters(in: .whitespacesAndNewlines) == "Ssl_cipher", "connected unencrypted")
        } catch let failure as ExternalTool.Failure {
            XCTAssertTrue(failure.message.contains("SSL"), failure.message)
        }
    }

    /// Options in the user's own ~/.my.cnf (read after a
    /// `--defaults-extra-file`, so they'd win) must not change what's
    /// dumped: here one that leaves out every row.
    func testTheUsersOwnOptionFileCantChangeTheDump() async throws {
        let tool = try await installedTool(.dump)
        let admin = MySQLService()
        try await admin.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                                password: TestDatabase.password, database: nil)
        let database = "mysqlmacclient_tool_home"
        _ = try await admin.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        _ = try await admin.rawQuery("CREATE DATABASE `\(database)`")
        _ = try await admin.rawQuery("CREATE TABLE `\(database)`.t (id INT PRIMARY KEY)")
        _ = try await admin.rawQuery("INSERT INTO `\(database)`.t VALUES (42)")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "[mysqldump]\nno-data\n".write(to: home.appendingPathComponent(".my.cnf"), atomically: true, encoding: .utf8)
        let dumpURL = home.appendingPathComponent("dump.sql")
        FileManager.default.createFile(atPath: dumpURL.path, contents: nil)
        let realHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        do {
            let output = try FileHandle(forWritingTo: dumpURL)
            let connection = try await admin.externalToolConnection()
            _ = try await tool.run(try tool.dumpArguments(database: database, connection: connection),
                                   optionFile: connection.optionFile, output: output)
            try output.close()
            // MariaDB's puts the rows on the line after VALUES.
            XCTAssertNotNil(try String(contentsOf: dumpURL, encoding: .utf8).firstMatch(of: /INSERT INTO `t` VALUES\s*\(42\)/))
        } catch {
            XCTFail("\(error)")
        }
        if let realHome { setenv("HOME", realHome, 1) }
        try? FileManager.default.removeItem(at: home)
        _ = try? await admin.rawQuery("DROP DATABASE IF EXISTS `\(database)`")
        try await admin.disconnect()
    }

    /// A password with every character an option file treats specially gets
    /// through the option file intact.
    func testThePasswordReachesTheToolThroughItsOptionFile() async throws {
        let tool = try await installedTool(.client)
        let admin = MySQLService()
        try await admin.connect(host: TestDatabase.host, port: TestDatabase.port, username: TestDatabase.username,
                                password: TestDatabase.password, database: nil)
        let user = "mmc_tool_\(UUID().uuidString.prefix(8).lowercased())"
        let password = " a\"b\\c#d'e=f é\\"
        _ = try await admin.rawQuery("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(SQLExporter.escapeStringLiteral(password))'")
        do {
            let connection = ExternalTool.Connection(host: TestDatabase.host, port: TestDatabase.port, username: user, tls: nil,
                                                     serverName: nil, optionFile: ExternalTool.optionFile(password: password))
            let current = try await execute("SELECT CURRENT_USER()", with: tool, connection)
            XCTAssertEqual(current.trimmingCharacters(in: .whitespacesAndNewlines), "\(user)@%")
        } catch {
            XCTFail("\(error)")
        }
        _ = try? await admin.rawQuery("DROP USER '\(user)'@'%'")
        try await admin.disconnect()
    }
}
