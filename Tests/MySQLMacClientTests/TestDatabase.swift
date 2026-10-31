import Foundation

/// The MySQL/MariaDB server the database tests connect to. Defaults to a
/// local server on 127.0.0.1:3306 as `root` with no password; each value can
/// be overridden from the environment, which is how `testenv/run-tests.sh`
/// points the tests at its Docker server instead.
enum TestDatabase {
    private static let environment = ProcessInfo.processInfo.environment

    static let host = environment["MYSQL_TEST_HOST"] ?? "127.0.0.1"
    static let port = environment["MYSQL_TEST_PORT"].flatMap(Int.init) ?? 3306
    static let username = environment["MYSQL_TEST_USER"] ?? "root"
    static let password = environment["MYSQL_TEST_PASSWORD"]
}
