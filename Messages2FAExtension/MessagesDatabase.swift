import Foundation
import SQLite3

enum MessagesDatabase {
  static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library", directoryHint: .isDirectory)
    .appending(path: "Messages", directoryHint: .isDirectory)
    .appending(path: "chat.db", directoryHint: .notDirectory)

  struct Message: Sendable {
    let guid: String
    let sender: String
    let body: String
    let receivedAt: Date
  }

  struct LoadError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
  }

  static func fetchRecentMessages(
    from url: URL = defaultDatabaseURL,
    lookBackMinutes: Int,
    ignoreRead: Bool,
    now: Date = .now
  ) throws -> [Message] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw LoadError(message: "Messages database was not found on this Mac.")
    }

    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
    guard openResult == SQLITE_OK, let database else {
      let detail = database.flatMap(sqliteMessage) ?? "Unable to open the Messages database."
      if let database { sqlite3_close(database) }
      throw LoadError(
        message: "Enable Full Disk Access for Tuna to read Messages.\n\(detail)"
      )
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 1_000)

    let readClause = ignoreRead ? "AND message.is_read = 0" : ""
    let sql = """
      SELECT
        message.guid,
        COALESCE(handle.uncanonicalized_id, handle.id, chat.chat_identifier, 'Unknown Sender'),
        message.text,
        message.attributedBody,
        message.date
      FROM message
      LEFT JOIN handle ON handle.ROWID = message.handle_id
      LEFT JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
      LEFT JOIN chat ON chat.ROWID = chat_message_join.chat_id
      WHERE message.is_from_me = 0
        AND (message.text IS NOT NULL OR message.attributedBody IS NOT NULL)
        AND message.date >= ?
        \(readClause)
      GROUP BY message.ROWID
      ORDER BY message.date DESC
      LIMIT 100
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw LoadError(message: sqliteMessage(database))
    }
    defer { sqlite3_finalize(statement) }

    let cutoff = now.addingTimeInterval(-Double(max(1, lookBackMinutes) * 60))
    sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSinceReferenceDate * 1_000_000_000))

    var messages: [Message] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let guid = textColumn(statement, 0)
      guard !guid.isEmpty else { continue }
      let plainText = textColumn(statement, 2)
      let attributedText = dataColumn(statement, 3).map(MessagesAttributedBodyDecoder.decode) ?? ""
      let body = [plainText, attributedText]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
      guard !body.isEmpty else { continue }

      let rawDate = sqlite3_column_int64(statement, 4)
      messages.append(
        Message(
          guid: guid,
          sender: textColumn(statement, 1),
          body: body,
          receivedAt: Date(timeIntervalSinceReferenceDate: Double(rawDate) / 1_000_000_000)
        )
      )
    }

    if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
      throw LoadError(message: sqliteMessage(database))
    }
    return messages
  }

  private static func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private static func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0 else { return nil }
    return Data(bytes: bytes, count: count)
  }

  private static func sqliteMessage(_ database: OpaquePointer) -> String {
    sqlite3_errmsg(database).map(String.init(cString:)) ?? "Messages database query failed."
  }
}

enum MessagesAttributedBodyDecoder {
  static func decode(_ data: Data) -> String {
    let decoded = String(decoding: data, as: UTF8.self)
    let hasArchiveMarkers = decoded.contains("streamtyped")
      || decoded.contains("NSAttributedString")
      || decoded.contains("NSString")
    guard hasArchiveMarkers else { return decoded }

    let candidates = decoded.unicodeScalars.split { scalar in
      scalar.value < 0x20 || scalar.value == 0x7f || scalar == "�"
    }
    .map { String(String.UnicodeScalarView($0)) }
    .filter { candidate in
      candidate.count >= 3
        && !candidate.contains("NSAttributedString")
        && !candidate.contains("NSMutableString")
        && !candidate.contains("NSDictionary")
        && !candidate.contains("streamtyped")
        && (candidate.contains(where: \Character.isWhitespace) || candidate.contains(where: \Character.isNumber))
    }

    return candidates.max(by: { score($0) < score($1) })?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func score(_ candidate: String) -> Int {
    candidate.count + (candidate.contains(where: \Character.isWhitespace) ? 1_000 : 0)
  }
}
