import Foundation
import Testing
import GRDB
@testable import PostvakCore

@Suite(.serialized) struct AccountBadgeTests {
    @Test func testDefaultLetterComesFromTheCompanyOrMarksAPersonalAddress() {
        XCTAssertEqual(Account.defaultBadge(for: "anna@gmail.com"), "P")
        XCTAssertEqual(Account.defaultBadge(for: "anna@zonnehoek.be"), "Z")
        XCTAssertEqual(Account.defaultBadge(for: "anna@getbrightly.com"), "B")
        // A short name after "get" stays whole.
        XCTAssertEqual(Account.defaultBadge(for: "anna@getit.be"), "G")
    }

    @Test func testChosenLetterIsSavedAndClearingItRestoresTheDefault() async throws {
        let engine = try makeEngine(accounts: ["anna@panelwerk.be"])
        let read = { try await engine.db.pool.read { try Account.fetchOne($0, key: "anna@panelwerk.be") }! }
        XCTAssertEqual(try await read().badgeLetter, "P")
        try await engine.setAccountBadge("anna@panelwerk.be", "w")
        XCTAssertEqual(try await read().badgeLetter, "W")
        try await engine.setAccountBadge("anna@panelwerk.be", nil)
        XCTAssertNil(try await read().badge)
        XCTAssertEqual(try await read().badgeLetter, "P")
    }
}
