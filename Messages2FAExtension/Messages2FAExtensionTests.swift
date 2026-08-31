import Foundation
import SQLite3
import TunaKit
import XCTest

@testable import TunaMessages2FA

final class Messages2FAExtensionTests: XCTestCase {
  func testExtractsReferenceCodeFormatsAndAvoidsPhoneNumbersAndURLs() {
    let examples: [(String, String)] = [
      ("2773 is your Microsoft account verification code", "2773"),
      ("Your Airbnb verification code is: 1234.", "1234"),
      ("Please enter code 548 on Zocdoc.", "548"),
      ("您的验证码是 199035，10分钟内有效，请勿泄露", "199035"),
      ("G-315643 is your Google verification code", "315643"),
      ("Your Stripe verification code is: 719-839.", "719839"),
      ("Your code is: 5WGU8G", "5WGU8G"),
      ("Código de Autorização: 12345678", "12345678"),
    ]

    for (message, expected) in examples {
      XCTAssertEqual(AuthenticationCodeExtractor.extract(from: message), expected, message)
    }
    XCTAssertNil(AuthenticationCodeExtractor.extract(from: "Call 800-531-8722 for support"))
    XCTAssertNil(AuthenticationCodeExtractor.extract(from: "https://example.com/login/123456"))
  }

  func testUsesLastContextualCode() {
    XCTAssertEqual(
      AuthenticationCodeExtractor.extract(from: "test code: 111111, replacement code: 883848"),
      "883848"
    )
  }

  func testDecodesAttributedMessageBody() {
    let data = Data(
      "\u{04}\u{0B}streamtyped\u{00}NSMutableAttributedString\u{00}Your access code is: 643066\u{00}NSDictionary".utf8
    )

    let decoded = MessagesAttributedBodyDecoder.decode(data)

    XCTAssertTrue(decoded.contains("643066"))
    XCTAssertFalse(decoded.contains("NSMutableAttributedString"))
  }

  func testDatabaseReadsOnlyRecentIncomingMessages() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    var databasePointer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &databasePointer), SQLITE_OK)
    let database = try XCTUnwrap(databasePointer)
    defer { sqlite3_close(database) }
    try execute(
      database,
      """
      CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, handle_id INTEGER, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, is_read INTEGER);
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
      CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      """
    )
    try execute(database, "INSERT INTO handle VALUES (1, '+15551234567', 'Example')")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let recent = Int64(now.addingTimeInterval(-60).timeIntervalSinceReferenceDate * 1_000_000_000)
    let old = Int64(now.addingTimeInterval(-3_600).timeIntervalSinceReferenceDate * 1_000_000_000)
    try execute(database, "INSERT INTO message VALUES (1, 'recent', 1, 'Your code is 123456', NULL, \(recent), 0, 0)")
    try execute(database, "INSERT INTO message VALUES (2, 'outgoing', 1, 'Your code is 222222', NULL, \(recent), 1, 0)")
    try execute(database, "INSERT INTO message VALUES (3, 'old', 1, 'Your code is 333333', NULL, \(old), 0, 0)")

    let messages = try MessagesDatabase.fetchRecentMessages(
      from: url,
      lookBackMinutes: 10,
      ignoreRead: false,
      now: now
    )

    XCTAssertEqual(messages.map(\.guid), ["recent"])
    XCTAssertEqual(messages.first?.sender, "Example")
  }

  @MainActor
  func testDeclarationAndCatalogKeepCodesBehindBrowse() throws {
    let instance = try Messages2FAExtension(bundle: Bundle(for: Messages2FAExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.catalogs.map(\.id), ["messages-2fa"])
    XCTAssertEqual(declaration.catalogs.first?.presentation, .source)
    XCTAssertEqual(declaration.appBrowseEnrichments.first?.bundleIdentifiers, ["com.apple.MobileSMS"])
    XCTAssertTrue(declaration.actionCatalogs.isEmpty)

    let catalog = Messages2FACatalog(
      identifier: "messages-2fa",
      databaseURL: URL(fileURLWithPath: "/missing/chat.db")
    )
    XCTAssertEqual(catalog.objects.count, 1)
    XCTAssertTrue(catalog.objects.first is DeferredBrowseCatalogItem)
    XCTAssertEqual(catalog.objects.first?.typeID, .searchCatalogEntry)
  }

  private func execute(_ database: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &error)
    guard result == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "SQLite error"
      sqlite3_free(error)
      throw NSError(domain: "Messages2FAExtensionTests", code: Int(result), userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}
