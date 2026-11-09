import XCTest
@testable import HermesIOSCore

final class SentAttachmentsTests: XCTestCase {
    func testTheAppsOwnLinesBecomeChips() {
        let split = SentAttachments.split("Prépare un courriel avec ça\n\n📎 facture.pdf\n📎 Photo-1a2b.jpg")
        XCTAssertEqual(split.text, "Prépare un courriel avec ça"); XCTAssertEqual(split.files, ["facture.pdf", "Photo-1a2b.jpg"])
    }

    func testHermesReferencesFromTheHistoryToo() {
        let split = SentAttachments.split("@file:attachments/facture.pdf\n@file:\"attachments/Mon relevé.pdf\"\n@file:\"attachments/facture (texte).txt\"\n@file:attachments/scan%20-%20page%201.jpg\n\nRésume-les")
        XCTAssertEqual(split.files, ["facture.pdf", "Mon relevé.pdf"], "the extracted text and the scanned pages are the PDF itself")
        XCTAssertEqual(split.text, "Résume-les")
    }

    func testAMessageWithoutFilesIsUntouched() {
        let text = "Écris à julie@example.com\n\nMerci"
        XCTAssertEqual(SentAttachments.split(text).text, text); XCTAssertTrue(SentAttachments.split(text).files.isEmpty)
    }

    func testKinds() {
        XCTAssertEqual(AttachmentKind.of(name: "a.PDF"), .pdf); XCTAssertEqual(AttachmentKind.of(name: "x", mimeType: "image/heic"), .image)
        XCTAssertEqual(AttachmentKind.of(name: "b.xlsx"), .sheet); XCTAssertEqual(AttachmentKind.of(name: "b.xlsx").label(for: "b.xlsx"), "XLSX")
        XCTAssertEqual(AttachmentKind.of(name: "sans-extension").label(for: "sans-extension"), "Fichier")
    }
}
