import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix

/// `MySQLQueryMetadata` (from MySQLNIO) isn't `Sendable`, so it can't cross
/// the actor boundary back to the caller — this is a Sendable stand-in
/// carrying just the two fields callers need.
struct ExecuteResult: Sendable {
    let affectedRows: UInt64
    let lastInsertID: UInt64?
}

/// Result of an arbitrary, user-authored SQL statement (the query editor):
/// unlike `query`/`execute`, the caller doesn't know ahead of time whether
/// it's a SELECT (rows matter) or an INSERT/UPDATE/DDL (affected-row count
/// matters), so this carries both.
struct RawQueryResult: Sendable {
    /// One entry per result set, each with its own columns. Ordinary
    /// statements produce at most one; a `CALL` to a procedure whose body
    /// runs several `SELECT`s produces one per `SELECT`, which the console
    /// shows as separate tabs. Empty for a write/DDL — and *only* for
    /// those: a `SELECT` that matched nothing still produces one entry,
    /// with its columns and no rows, so the console can draw an empty grid
    /// with real headers instead of leaving the previous result on screen.
    let resultSets: [MySQLResultSet]
    let affectedRows: UInt64?
    let lastInsertID: UInt64?

    /// The first result set's rows — what a single-result caller means by
    /// "the rows", and what the grid shows when it isn't tab-aware.
    var rows: [MySQLRow] { resultSets.first?.rows ?? [] }

    init(resultSets: [MySQLResultSet], affectedRows: UInt64?, lastInsertID: UInt64?) {
        self.resultSets = resultSets
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
    }
}

enum MySQLServiceError: Error, LocalizedError {
    case notConnected
    case invalidIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to a database.")
        case .invalidIdentifier(let identifier):
            return String(localized: "Invalid table/column name: \(identifier)")
        }
    }
}

/// Owns a single `MySQLConnection` and the `EventLoopGroup` it runs on.
/// No pooling in the MVP: one connection per app session, created on
/// `connect` and torn down on `disconnect`.
actor MySQLService {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var connection: MySQLConnection?

    /// Kept so a dropped connection can be silently re-established — shared
    /// hosts (cPanel/remote MySQL) commonly kill idle TCP connections at the
    /// network/firewall level; the client only learns about it on the next
    /// write, as `MySQLError.closed`. A single long-lived connection with no
    /// pooling (the MVP's explicit tradeoff) needs this to stay usable
    /// across a normal session instead of erroring on every idle gap.
    private var lastCredentials: (host: String, port: Int, username: String, password: String?, database: String?)?

    private(set) var isConnected: Bool = false

    /// Off for a connection opened for one job (`openSeparateConnection`):
    /// a new session would have lost the job's database and settings, so a
    /// drop has to end the job rather than carry on somewhere else.
    private var reconnectsAutomatically = true

    /// Whatever `SELECT VERSION()` returned on connect — e.g.
    /// `"10.4.32-MariaDB"` or `"8.0.45"`. Read once per connection rather
    /// than per use: it can't change under a live connection, and error
    /// messages that want to name the server (see
    /// `SQLConsoleViewModel`'s unknown-collation hint) shouldn't have to
    /// round-trip to the server to do it. `nil` if that probe failed —
    /// never a reason to fail the connection itself.
    private(set) var serverVersion: String?

    /// `database: nil` connects with no default schema selected — MySQL
    /// allows this, and the caller is then expected to browse
    /// `SHOW DATABASES` and qualify every query as `` `db`.`table` ``.
    func connect(host: String, port: Int, username: String, password: String?, database: String?) async throws {
        if connection != nil {
            try await disconnect()
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)

        do {
            let conn = try await MySQLConnection.connect(
                to: address,
                username: username,
                database: database ?? "",
                password: password,
                tlsConfiguration: nil,
                on: eventLoop
            ).get()
            // MySQLNIO's login asks for collation 255, which only MySQL 8
            // knows; MariaDB silently falls back to its default (often
            // latin1) and would then store the UTF-8 this app sends as
            // double-encoded text. Every reconnect comes through here too.
            do {
                _ = try await conn.simpleQuery("SET NAMES utf8mb4").get()
            } catch {
                try? await conn.close().get()
                throw error
            }
            self.eventLoopGroup = group
            self.connection = conn
            self.isConnected = true
            self.lastCredentials = (host, port, username, password, database)
            // Best-effort: a server that won't answer this is still a
            // perfectly usable connection, so a failure here is swallowed
            // rather than surfaced.
            self.serverVersion = try? await conn.simpleQuery("SELECT VERSION() AS version").get()
                .first?.column("version")?.string
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// A second connection with this one's credentials, for a job that
    /// changes its session (a restore runs USE and the file's own SET
    /// statements) and so mustn't share the connection the rest of the app
    /// is using. It starts in no database, since the one this connection
    /// logged in to may have been dropped since, and it doesn't reconnect
    /// by itself.
    func openSeparateConnection() async throws -> MySQLService {
        guard let credentials = lastCredentials else { throw MySQLServiceError.notConnected }
        let separate = MySQLService()
        try await separate.connect(
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            database: nil
        )
        await separate.disableAutomaticReconnect()
        return separate
    }

    private func disableAutomaticReconnect() {
        reconnectsAutomatically = false
    }

    func disconnect() async throws {
        lastCredentials = nil
        serverVersion = nil
        guard let conn = connection else { return }
        await acquire()
        defer { release() }
        connection = nil
        isConnected = false
        try? await conn.close().get()
        try await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil
    }

    func query(_ sql: String, _ binds: [MySQLData] = []) async throws -> [MySQLRow] {
        try await withRetryOnClosedConnection {
            try await self.withExclusiveConnectionAccess { conn in
                try await conn.query(sql, binds).get()
            }
        }
    }

    /// `query` over the text protocol, which carries every value as the
    /// server's own text. The binary protocol `query` uses is lossy for
    /// some types once decoded (DECIMAL, BIT wider than 8 bits, YEAR,
    /// TIME), so a backup, which has to write values back exactly, reads
    /// with this instead. Takes no binds.
    func textQuery(_ sql: String) async throws -> [MySQLRow] {
        try await withRetryOnClosedConnection {
            try await self.withExclusiveConnectionAccess { conn in
                try await conn.simpleQuery(sql).get()
            }
        }
    }

    @discardableResult
    func execute(_ sql: String, _ binds: [MySQLData] = []) async throws -> ExecuteResult {
        try await withRetryOnClosedConnection {
            try await self.withExclusiveConnectionAccess { conn in
                let box = MetadataBox()
                _ = try await conn.query(sql, binds, onRow: { _ in }, onMetadata: { metadata in
                    box.affectedRows = metadata.affectedRows
                    box.lastInsertID = metadata.lastInsertID
                }).get()
                return ExecuteResult(affectedRows: box.affectedRows ?? 0, lastInsertID: box.lastInsertID)
            }
        }
    }

    /// For the SQL query editor: runs whatever the user typed as-is. Unlike
    /// every other query in this app, this is deliberately *not*
    /// identifier-whitelisted or otherwise sanitized — a raw SQL editor
    /// exists precisely so the user can run arbitrary SQL, same as
    /// SQLyog/DBeaver/phpMyAdmin's query tabs. This must never be reachable
    /// from anything other than that editor's own explicit "run" action.
    func rawQuery(_ sql: String) async throws -> RawQueryResult {
        try await withRetryOnClosedConnection {
            try await self.withExclusiveConnectionAccess { conn in
                do {
                    let box = MetadataBox()
                    let resultSets = try await conn.queryResultSets(sql, [], onMetadata: { metadata in
                        box.affectedRows = metadata.affectedRows
                        box.lastInsertID = metadata.lastInsertID
                    }).get()
                    return RawQueryResult(resultSets: resultSets, affectedRows: box.affectedRows, lastInsertID: box.lastInsertID)
                } catch MySQLError.server(let packet) where packet.errorCode == .UNSUPPORTED_PS {
                    // `ER_UNSUPPORTED_PS` (1295) — MySQL rejects a whole
                    // category of statements (`USE db`, `CREATE PROCEDURE`/
                    // `FUNCTION`/`TRIGGER`/`EVENT`, …) from the
                    // prepared-statement protocol, which is what
                    // `conn.query(_:_:)` always uses even with no binds.
                    // Rather than enumerate every affected statement kind
                    // up front, retry once through the plain-text
                    // `simpleQuery` path — the same one the real `mysql`
                    // CLI uses — whenever the server says this specific
                    // statement can't be prepared.
                    //
                    // NOTE: `ER_SP_BADSELECT` (1312) — `CALL`ing a
                    // procedure whose body runs a `SELECT` — looks like the
                    // same class of problem but isn't: it comes from the
                    // `CLIENT_MULTI_RESULTS` capability never being
                    // requested in MySQLNIO's connection handshake
                    // (`CapabilityFlags.clientDefault`, hardcoded, no
                    // public override). That's a per-*connection*
                    // capability, not a per-*query* protocol choice, so
                    // retrying via `simpleQuery` here wouldn't help — it
                    // fails identically either way. Calling a procedure
                    // that returns a result set isn't supported by this
                    // client until MySQLNIO exposes that capability flag.
                    let resultSets = try await conn.simpleQueryResultSets(sql).get()
                    return RawQueryResult(resultSets: resultSets, affectedRows: nil, lastInsertID: nil)
                } catch is MySQLProtocol.COM_STMT_PREPARE_OK.Error {
                    // Some MariaDB servers reply to `COM_STMT_PREPARE` for
                    // certain statements (confirmed with `SET GLOBAL
                    // event_scheduler = ON`) with a shorter payload than
                    // MySQLNIO's decoder expects — it throws while reading
                    // one of `COM_STMT_PREPARE_OK`'s fixed fields (missing
                    // status/statementID/numColumns/numParams/etc.), not a
                    // clean `ER_UNSUPPORTED_PS` server error, so it doesn't
                    // hit the catch above. Since the failure happens while
                    // decoding the *prepare* response — before any
                    // `COM_STMT_EXECUTE` — nothing has run against the
                    // server yet, so retrying via the plain-text protocol
                    // here is exactly as safe as the `ER_UNSUPPORTED_PS`
                    // case.
                    let resultSets = try await conn.simpleQueryResultSets(sql).get()
                    return RawQueryResult(resultSets: resultSets, affectedRows: nil, lastInsertID: nil)
                }
            }
        }
    }

    /// Retries exactly once, and only for a connection that's actually
    /// dead — never for query errors like bad SQL or a duplicate key, which
    /// would just fail identically (or worse, double-apply a write) on retry.
    private func withRetryOnClosedConnection<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch MySQLError.closed {
            guard reconnectsAutomatically, let credentials = lastCredentials else { throw MySQLError.closed }
            try await connect(
                host: credentials.host,
                port: credentials.port,
                username: credentials.username,
                password: credentials.password,
                database: credentials.database
            )
            return try await operation()
        }
    }

    // MARK: - Serialization

    // MySQL's wire protocol has no pipelining: only one command may be in
    // flight on a connection at a time. Actors alone don't guarantee that —
    // a suspended `await` lets another call into the actor and, without this
    // gate, two views switching quickly would both send commands on the same
    // connection at once, desyncing the protocol and getting the connection
    // closed by the server. This FIFO gate makes each query/execute wait its
    // turn instead.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            isBusy = false
        }
    }

    private func withExclusiveConnectionAccess<T>(_ body: (MySQLConnection) async throws -> T) async throws -> T {
        guard let conn = connection else { throw MySQLServiceError.notConnected }
        await acquire()
        defer { release() }
        return try await body(conn)
    }

    private final class MetadataBox: @unchecked Sendable {
        // nil (not 0) until `onMetadata` actually fires — a SELECT never
        // triggers it, so `nil` is how a raw query tells "no affected-row
        // count" (it was a read) apart from "matched zero rows" (a write).
        var affectedRows: UInt64?
        var lastInsertID: UInt64?
    }
}
