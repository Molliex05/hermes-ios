import XCTest
@testable import HermesIOSCore

final class ConversationTitleTests: XCTestCase {
    func testTitlesAreShownOnOneLineWithoutQuotes() {
        XCTAssertEqual(ConversationTitle.clean("  « Facture Google Workspace »  "), "Facture Google Workspace")
        XCTAssertEqual(ConversationTitle.clean("\"Brouillon pour Julie\"\nAutre ligne"), "Brouillon pour Julie")
        XCTAssertNil(ConversationTitle.clean("  \n "))
        XCTAssertEqual(ConversationTitle.clean(String(repeating: "a", count: 120))?.count, 80)
    }
}
