import GRDB
import SherpaOnnxC
import XCTest
import llama

/// P0.5: each third-party dependency links and runs on this platform.
final class DependencyLinkTests: XCTestCase {
    func testGRDBHasFTS5() throws {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(text)")
            try db.execute(sql: "INSERT INTO t(text) VALUES ('the optimizer is called Adam')")
        }
        let hits = try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t WHERE t MATCH 'adam'") }
        XCTAssertEqual(hits, 1)
    }

    func testLlamaLinks() {
        let info = String(cString: llama_print_system_info())
        XCTAssertFalse(info.isEmpty)
    }

    func testSherpaLinksWithoutTTS() {
        let version = String(cString: SherpaOnnxGetVersionStr())
        XCTAssertEqual(version, "1.13.8")
    }
}
