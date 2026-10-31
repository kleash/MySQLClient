import XCTest
@testable import MySQLMacClient

/// Pure string splitting — no database needed.
final class DelimiterScriptTests: XCTestCase {
    func testReturnsNilWhenNoDelimiterDirectiveIsPresent() {
        XCTAssertNil(DelimiterScript.statements(from: "SELECT * FROM `t`;"))
        XCTAssertNil(DelimiterScript.statements(from: "INSERT INTO `t` (`a`) VALUES ('x');\nINSERT INTO `t` (`a`) VALUES ('y');"))
    }

    /// The exact shape "Alter View" produces: `USE`, `DROP VIEW IF EXISTS`,
    /// then a multi-line `CREATE VIEW`, each `$$`-terminated.
    func testSplitsAlterViewScriptIntoThreeStatements() {
        let script = [
            "DELIMITER $$",
            "",
            "USE `mydb`$$",
            "",
            "DROP VIEW IF EXISTS `test`$$",
            "",
            "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `test` AS ",
            "SELECT",
            "  `t`.`id` AS `id`",
            "FROM `t`$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")

        let statements = DelimiterScript.statements(from: script)
        XCTAssertEqual(statements, [
            "USE `mydb`",
            "DROP VIEW IF EXISTS `test`",
            "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `test` AS \nSELECT\n  `t`.`id` AS `id`\nFROM `t`",
        ])
    }

    /// A `CREATE PROCEDURE ... BEGIN ... END$$` body's internal `;`s must
    /// stay untouched — only the `$$` terminator ends the statement.
    func testPreservesSemicolonsInsideDelimiterTerminatedBody() {
        let script = [
            "DELIMITER $$",
            "",
            "CREATE PROCEDURE `p`()",
            "BEGIN",
            "    SELECT 1;",
            "    SELECT 2;",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")

        let statements = DelimiterScript.statements(from: script)
        XCTAssertEqual(statements?.count, 1)
        XCTAssertEqual(statements?.first, "CREATE PROCEDURE `p`()\nBEGIN\n    SELECT 1;\n    SELECT 2;\nEND")
    }

    func testIgnoresBareDelimiterLineWithNoToken() {
        // Malformed input (no token after the keyword) shouldn't crash or
        // silently swallow the rest of the script.
        let script = "DELIMITER\nSELECT 1;"
        XCTAssertNil(DelimiterScript.statements(from: script))
    }

    // MARK: - allStatements(from:) — "Tümünü Çalıştır"

    /// The exact reported case: two independent statements, each on its
    /// own line, no `DELIMITER` in sight — `statements(from:)` opts out of
    /// this (see `testReturnsNilWhenNoDelimiterDirectiveIsPresent`) but
    /// `allStatements(from:)` must still split it, since that's the whole
    /// point of the "Tümünü Çalıştır" button.
    func testAllStatementsSplitsAPlainScriptWithNoDelimiterDirective() {
        let script = "USE cantokay_adres_tr;\ncall addNew();"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "USE cantokay_adres_tr",
            "call addNew()",
        ])
    }

    /// A single statement (with or without a trailing `;`) still comes
    /// back as one element, not an empty array or a stray empty string.
    func testAllStatementsReturnsOneElementForASingleStatement() {
        XCTAssertEqual(DelimiterScript.allStatements(from: "SELECT 1;"), ["SELECT 1"])
        XCTAssertEqual(DelimiterScript.allStatements(from: "SELECT 1"), ["SELECT 1"])
    }

    /// `allStatements(from:)` is a strict superset of `statements(from:)` —
    /// a script that *does* have a `DELIMITER` directive splits identically
    /// either way.
    func testAllStatementsHonorsADelimiterDirectiveWhenPresent() {
        let script = [
            "DELIMITER $$",
            "",
            "CREATE PROCEDURE `p`()",
            "BEGIN",
            "    SELECT 1;",
            "END$$",
            "",
            "DELIMITER ;",
        ].joined(separator: "\n")

        XCTAssertEqual(DelimiterScript.allStatements(from: script), DelimiterScript.statements(from: script))
    }

    // MARK: - Terminators the splitter must and must not honor

    /// The reported case: a remark after the `;` kept `SET NAMES` from
    /// ending, so it was sent glued to the `ALTER TABLE` below it and the
    /// server rejected the pair with a syntax error "near 'ALTER TABLE'".
    func testAllStatementsEndsAStatementBeforeATrailingComment() {
        let script = [
            "-- Run this file once (e.g. paste it into phpMyAdmin's SQL tab).",
            "",
            "SET NAMES utf8mb4; -- names like \"Türkiye\" and \"Côte d'Ivoire\"",
            "",
            "-- Step 1 — the new column.",
            "ALTER TABLE analytics_events",
            "    ADD COLUMN device_name VARCHAR(80) NULL AFTER device_id,",
            "    ADD KEY idx_device_id (device_id);",
        ].joined(separator: "\n")

        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "SET NAMES utf8mb4",
            "ALTER TABLE analytics_events\n    ADD COLUMN device_name VARCHAR(80) NULL AFTER device_id,\n    ADD KEY idx_device_id (device_id)",
        ])
    }

    func testAllStatementsSplitsSeveralStatementsOnOneLine() {
        XCTAssertEqual(DelimiterScript.allStatements(from: "USE db; CALL p(); SELECT 1"), ["USE db", "CALL p()", "SELECT 1"])
    }

    /// A `;` inside a string or a quoted identifier is data, wherever on
    /// the line it sits — including the end, where the old line-based
    /// splitter cut the statement in half.
    func testAllStatementsKeepsTerminatorsInsideQuotes() {
        let script = [
            "INSERT INTO t (a) VALUES ('first;",
            "second');",
            #"INSERT INTO t (a) VALUES ('it''s; fine'), ('it\'s; fine'), ("say \"hi\"; ok");"#,
            "SELECT `odd;name` FROM t;",
        ].joined(separator: "\n")

        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "INSERT INTO t (a) VALUES ('first;\nsecond')",
            #"INSERT INTO t (a) VALUES ('it''s; fine'), ('it\'s; fine'), ("say \"hi\"; ok")"#,
            "SELECT `odd;name` FROM t",
        ])
    }

    /// Comments can hold terminators and stray quotes without either
    /// meaning anything: an apostrophe in prose must not open a string
    /// that swallows the statements after it.
    func testAllStatementsIgnoresTerminatorsAndQuotesInsideComments() {
        let script = [
            "SELECT 1 -- don't stop here; really",
            ";",
            "SELECT 2; # it's a hash comment; still one",
            "SELECT /* inline; isn't code */ 3;",
        ].joined(separator: "\n")

        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "SELECT 1 -- don't stop here; really",
            "SELECT 2",
            "SELECT /* inline; isn't code */ 3",
        ])
    }

    /// Comments ahead of a statement aren't part of it, and comments with
    /// no statement after them aren't one — the server answers a
    /// comment-only query with "Query was empty".
    func testAllStatementsDropsCommentOnlyStretches() {
        let script = "-- header\n/* block */\nSELECT 1;\n-- closing remark\n# and another\n"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), ["SELECT 1"])
        XCTAssertEqual(DelimiterScript.allStatements(from: "-- nothing to run here"), [])
    }

    /// mysqldump's preamble: version-gated "comments" are SQL the server
    /// runs, so each one is a statement in its own right.
    func testAllStatementsKeepsExecutableComments() {
        let script = "/*!40101 SET NAMES utf8mb4 */;\n/*M!100616 SET NOTE_VERBOSITY=0 */;\nSELECT 1;"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "/*!40101 SET NAMES utf8mb4 */",
            "/*M!100616 SET NOTE_VERBOSITY=0 */",
            "SELECT 1",
        ])
    }

    /// Inside an executable comment is SQL, and both the mysql and the
    /// MariaDB client read it as such: a `*/` in a string doesn't end the
    /// comment, and a delimiter ends the statement. mysqldump wraps trigger
    /// and view bodies in these.
    func testAllStatementsReadsTheInsideOfAnExecutableCommentAsSQL() {
        let script = """
            DELIMITER ;;
            /*!50003 CREATE*/ /*!50003 TRIGGER t_bu BEFORE UPDATE ON t FOR EACH ROW SET NEW.body = REPLACE(NEW.body, '*/', '') */;;
            DELIMITER ;
            /*!50001 VIEW `v_file` AS select regexp_replace(`t`.`path`,'^.*/','') AS `file` from `t` */;
            /*M!100100 SELECT concat('/* ',`t`.`body`,' */') FROM t */;
            SELECT 1 /*! , 2; */;
            SELECT 3;
            """
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "/*!50003 CREATE*/ /*!50003 TRIGGER t_bu BEFORE UPDATE ON t FOR EACH ROW SET NEW.body = REPLACE(NEW.body, '*/', '') */",
            "/*!50001 VIEW `v_file` AS select regexp_replace(`t`.`path`,'^.*/','') AS `file` from `t` */",
            "/*M!100100 SELECT concat('/* ',`t`.`body`,' */') FROM t */",
            "SELECT 1 /*! , 2",
            "*/",
            "SELECT 3",
        ])
    }

    /// `use <db>` alone on a line, with no delimiter, before a statement has
    /// started, is a command of its own to the MariaDB client (and to the
    /// mysql client with --commands), not the start of a statement that
    /// runs on into the next line.
    func testAllStatementsEndsAUseLineThatHasNoDelimiter() {
        let script = "use shop\nINSERT INTO t VALUES (1);\n  USE `shop` -- why\nSELECT 1,\nuse x\n, 2;\nuse shop; SELECT 3;"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "use shop",
            "INSERT INTO t VALUES (1)",
            "USE `shop` -- why",
            "SELECT 1,\nuse x\n, 2",
            "use shop",
            "SELECT 3",
        ])
    }

    /// `--` needs whitespace after it to be a comment, exactly as in
    /// MySQL — otherwise it's a double negation.
    func testAllStatementsTreatsDoubleDashWithoutSpaceAsArithmetic() {
        XCTAssertEqual(DelimiterScript.allStatements(from: "SELECT 5--3; SELECT 1"), ["SELECT 5--3", "SELECT 1"])
    }

    /// A script saved with Windows line endings splits the same way.
    func testAllStatementsHandlesCRLFLineEndings() {
        let script = "DELIMITER $$\r\nCREATE PROCEDURE `p`()\r\nBEGIN\r\n    SELECT 1;\r\nEND$$\r\nDELIMITER ;\r\nUSE db; -- note\r\nSELECT 2;\r\n"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "CREATE PROCEDURE `p`()\r\nBEGIN\r\n    SELECT 1;\r\nEND",
            "USE db",
            "SELECT 2",
        ])
    }

    /// A line reading `DELIMITER …` inside a string is text, not a
    /// directive.
    func testAllStatementsLeavesADelimiterLineInsideAStringAlone() {
        let script = "INSERT INTO notes (body) VALUES ('first line\nDELIMITER $$\nlast line');\nSELECT 1;"
        XCTAssertEqual(DelimiterScript.allStatements(from: script), [
            "INSERT INTO notes (body) VALUES ('first line\nDELIMITER $$\nlast line')",
            "SELECT 1",
        ])
    }

    /// An unterminated quote or comment runs to the end of the script
    /// instead of reading past it.
    func testAllStatementsSurvivesUnterminatedQuotesAndComments() {
        XCTAssertEqual(DelimiterScript.allStatements(from: "SELECT 'oops; SELECT 2;"), ["SELECT 'oops; SELECT 2;"])
        XCTAssertEqual(DelimiterScript.allStatements(from: "SELECT 1; /* never closed"), ["SELECT 1"])
        XCTAssertEqual(DelimiterScript.allStatements(from: #"SELECT 'ends in a backslash\"#), [#"SELECT 'ends in a backslash\"#])
        XCTAssertEqual(DelimiterScript.allStatements(from: ""), [])
    }

    // MARK: - Where each statement starts

    /// The server reports an error's line counted from the start of the
    /// statement it was sent, so each statement has to remember which
    /// line of the script it began on — its first line of SQL, not the
    /// comments above it.
    func testLocatedStatementsRecordTheLineEachStatementStartsOn() {
        let script = [
            "-- header",                    // 0
            "",                             // 1
            "SET NAMES utf8mb4; -- note",   // 2
            "",                             // 3
            "-- Step 1",                    // 4
            "ALTER TABLE t",                // 5
            "    ADD COLUMN c INT;",        // 6
            "SELECT 1; SELECT 2;",          // 7
        ].joined(separator: "\n")

        XCTAssertEqual(DelimiterScript.locatedStatements(from: script), [
            .init(sql: "SET NAMES utf8mb4", lineOffset: 2),
            .init(sql: "ALTER TABLE t\n    ADD COLUMN c INT", lineOffset: 5),
            .init(sql: "SELECT 1", lineOffset: 7),
            .init(sql: "SELECT 2", lineOffset: 7),
        ])
    }

    /// Line breaks inside a string or a block comment still move the
    /// statements after them down a line.
    func testLocatedStatementsCountLineBreaksInsideStringsAndComments() {
        let script = "INSERT INTO t VALUES ('a\nb\\\nc');\n/* one\ntwo */\nSELECT 1;\r\nSELECT 2;"
        XCTAssertEqual(DelimiterScript.locatedStatements(from: script).map(\.lineOffset), [0, 5, 6])
    }

    func testLocatedStatementsSkipDelimiterLinesWhenCounting() {
        let script = "DELIMITER $$\nCREATE PROCEDURE `p`()\nBEGIN\n    SELECT 1;\nEND$$\nDELIMITER ;\nSELECT 2;"
        XCTAssertEqual(DelimiterScript.locatedStatements(from: script).map(\.lineOffset), [1, 6])
    }

    // MARK: - Splitter (a script read in chunks)

    /// Every chunk size from one byte up must give exactly the statements,
    /// and lines, of splitting the whole script at once: cuts inside
    /// strings, comments, executable comments, multi-byte characters, a
    /// `DELIMITER` or `use` line and a two-character delimiter all have to
    /// come out the same.
    func testSplitterMatchesTheWholeScriptAtEveryChunkSize() throws {
        let script = """
            SET NAMES utf8mb4; -- comment; with a semicolon
            INSERT INTO t VALUES ('a;b', 'it''s', 'back\\'slash; x', "dq;", `c;`), ('😀 ünï 中文;');
            # hash comment;
            /* block; comment */ SELECT 1 /*! executable; */; /*!50001 SELECT '*/;' */;\r
            use db_x
            SELECT 5--3;
            DELIMITER $$
            CREATE PROCEDURE p()
            BEGIN
                SELECT ';$'; SELECT '$$ in a string';
            END$$
            DELIMITER ;
            SELECT 'DELIMITER $$ not a directive here'; SELECT 2;   DELIMITER ignored mid-line;
            SELECT 'unterminated last statement'
            """
        let expected = DelimiterScript.locatedStatements(from: script)
        XCTAssertEqual(expected.count, 12)
        let bytes = Array(script.utf8)
        for chunkSize in 1...bytes.count {
            var splitter = DelimiterScript.Splitter()
            var found: [(sql: [UInt8], line: Int)] = []
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                found += splitter.feed(bytes[start..<min(start + chunkSize, bytes.count)])
            }
            found += splitter.finish()
            let decoded = try found.map { statement in
                let text = try XCTUnwrap(String(bytes: statement.sql, encoding: .utf8), "cut inside a character at chunk size \(chunkSize)")
                return DelimiterScript.Statement(sql: text.trimmingCharacters(in: .whitespacesAndNewlines), lineOffset: statement.line)
            }
            XCTAssertEqual(decoded, expected, "chunk size \(chunkSize)")
        }
    }

    /// A server in NO_BACKSLASH_ESCAPES mode reads a backslash in a string
    /// as itself, so `'C:\'` is a whole string there. Only the server knows
    /// its mode once a statement has changed it, so the splitter stops after
    /// any statement that mentions sql_mode and reads the rest the way the
    /// caller then says the server does.
    func testSplitterReadsBackslashesInTheModeTheCallerSets() {
        func sql(_ found: [(sql: [UInt8], line: Int)]) -> [String] {
            found.map { String(decoding: $0.sql, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let script = "SET sql_mode = 'NO_BACKSLASH_ESCAPES';\nSELECT 'C:\\'; SELECT 2;\n/*!50003 SET SQL_MODE = '' */;\nSELECT 'it\\'s; one'; SELECT 3;\n"
        var splitter = DelimiterScript.Splitter()
        XCTAssertEqual(sql(splitter.feed(script.utf8)), ["SET sql_mode = 'NO_BACKSLASH_ESCAPES'"])
        splitter.noBackslashEscapes = true
        XCTAssertEqual(sql(splitter.feed(Data())), [#"SELECT 'C:\'"#, "SELECT 2", "/*!50003 SET SQL_MODE = '' */"])
        splitter.noBackslashEscapes = false
        XCTAssertEqual(sql(splitter.finish()), [#"SELECT 'it\'s; one'"#, "SELECT 3"])
    }
}
