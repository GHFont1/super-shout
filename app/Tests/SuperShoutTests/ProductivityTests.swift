import XCTest
@testable import SuperShout

final class ProductivityTests: XCTestCase {
    func testSnippetExpansionIsCaseInsensitiveAndWordBounded() {
        let snippets = [VoiceSnippet(trigger: "my address", replacement: "123 Main Street")]
        XCTAssertEqual(SnippetExpander.expand("Send it to My Address please", snippets: snippets), "Send it to 123 Main Street please")
        XCTAssertEqual(SnippetExpander.expand("notmy address", snippets: snippets), "notmy address")
    }

    func testAppModeResolutionIsExactAndCaseInsensitive() {
        let mode = AppMode(name: "Mail", bundleIdentifiers: ["com.apple.mail"], removeFillers: true, autoPunctuate: true, smartLists: true, aiPolish: true)
        XCTAssertEqual(AppModeResolver.resolve(bundleIdentifier: "COM.APPLE.MAIL", modes: [mode])?.name, "Mail")
        XCTAssertNil(AppModeResolver.resolve(bundleIdentifier: "com.apple.mail.helper", modes: [mode]))
    }

    func testTranscriptSearchIncludesMetadataAndSummary() {
        let record = TranscriptRecord(text: "Quarterly review", kind: .meeting, appName: "Zoom", summary: "Approve the inventory plan")
        XCTAssertTrue(record.searchableText.contains("inventory"))
        XCTAssertTrue(record.searchableText.contains("zoom"))
    }

    func testHistoryRetentionDefaultsCanPreserveEverything() throws {
        XCTAssertNil(HistoryRetention.forever.cutoff)
        let cutoff = try XCTUnwrap(HistoryRetention.thirtyDays.cutoff)
        XCTAssertEqual(Date().timeIntervalSince(cutoff), 30 * 24 * 60 * 60, accuracy: 2)
    }
}
