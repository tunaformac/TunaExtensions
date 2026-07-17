import Foundation
import SQLite3

enum NotesDatabase {
  private static let noteTitleCandidates = ["ZTITLE1", "ZTITLE2", "ZTITLE"]
  private static let folderTitleCandidates = ["ZTITLE2", "ZTITLE1", "ZTITLE"]
  private static let snippetCandidates = ["ZSNIPPET", "ZSUMMARY"]
  private static let modifiedDateCandidates = [
    "ZMODIFICATIONDATE1",
    "ZMODIFICATIONDATE",
    "ZMODIFICATIONDATE2",
  ]

  struct Record: Sendable {
    let identifier: String
    let title: String
    let folderName: String
    let snippet: String
    let modifiedAt: Date
  }

  struct LoadError: Error, Sendable {
    let title: String
    let message: String
    let symbolName: String
  }

  static func fetchNotes() -> Result<[Record], LoadError> {
    guard let url = defaultStoreURL() else {
      return .failure(
        LoadError(
          title: "Notes Unavailable",
          message: "Unable to locate your Notes database.",
          symbolName: "note.text"
        )
      )
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      return .failure(
        LoadError(
          title: "Notes Unavailable",
          message: "Notes database not found at \(url.path).",
          symbolName: "note.text"
        )
      )
    }

    do {
      let notes = try readNotes(from: url)
      return .success(notes)
    } catch let error as LoadError {
      return .failure(error)
    } catch {
      return .failure(
        LoadError(
          title: "Notes Unavailable",
          message: error.localizedDescription,
          symbolName: "exclamationmark.triangle.fill"
        )
      )
    }
  }

  private static func defaultStoreURL() -> URL? {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Group Containers", directoryHint: .isDirectory)
      .appending(path: "group.com.apple.notes", directoryHint: .isDirectory)
      .appending(path: "NoteStore.sqlite", directoryHint: .notDirectory)
  }

  private static func readNotes(from url: URL) throws -> [Record] {
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
    guard rc == SQLITE_OK, let db else {
      let message =
        db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
        ?? "Unable to open Notes database."
      throw LoadError(
        title: "Notes Access Needed",
        message: "Enable Full Disk Access for Tuna to read Notes.\n\(message)",
        symbolName: "lock.fill"
      )
    }
    defer { sqlite3_close(db) }

    let tables = try tableNames(in: db)
    guard tables.contains("ZICCLOUDSYNCINGOBJECT") else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unsupported Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }

    let cloudColumns = try columns(in: db, table: "ZICCLOUDSYNCINGOBJECT")

    let records: [Record]
    if tables.contains("Z_12NOTES") {
      records = try fetchUsingFolderJoinTable(
        db: db,
        cloudColumns: cloudColumns,
        joinTable: "Z_12NOTES"
      )
    } else {
      records = try fetchUsingCloudObjectsTable(db: db, cloudColumns: cloudColumns)
    }

    return records
  }

  private static func fetchUsingFolderJoinTable(
    db: OpaquePointer,
    cloudColumns: Set<String>,
    joinTable: String
  ) throws -> [Record] {
    let joinColumns = try columns(in: db, table: joinTable)

    let folderKey = ["Z_12FOLDERS", "Z_12FOLDER", "Z_1FOLDERS", "Z_1FOLDER"].first {
      joinColumns.contains($0)
    }
    let noteKey = ["Z_29NOTES", "Z_29NOTE", "Z_2NOTES", "Z_2NOTE"].first {
      joinColumns.contains($0)
    }

    guard let folderKey, let noteKey else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unsupported Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }

    guard
      let noteIdentifierColumn = preferredColumn(
        from: ["ZIDENTIFIER"],
        available: cloudColumns
      )
    else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unsupported Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }
    let noteTitleColumn = preferredColumn(from: noteTitleCandidates, available: cloudColumns)
    let folderTitleColumn = preferredColumn(from: folderTitleCandidates, available: cloudColumns)
    let snippetColumn = preferredColumn(from: snippetCandidates, available: cloudColumns)
    let modifiedColumn = preferredColumn(from: modifiedDateCandidates, available: cloudColumns)

    let selectTitle = noteTitleColumn.map { "note.\($0)" } ?? "\"\""
    let selectFolder = folderTitleColumn.map { "folder.\($0)" } ?? "\"\""
    let selectSnippet = snippetColumn.map { "note.\($0)" } ?? "\"\""
    let selectModified = modifiedColumn.map { "note.\($0)" } ?? "0"

    var whereParts: [String] = [
      "note.\(noteIdentifierColumn) IS NOT NULL",
      "note.\(noteIdentifierColumn) <> ''",
    ]

    if let titleColumn = noteTitleColumn {
      whereParts.append("note.\(titleColumn) IS NOT NULL")
      whereParts.append("note.\(titleColumn) <> ''")
    }

    if cloudColumns.contains("ZMARKEDFORDELETION") {
      whereParts.append("note.ZMARKEDFORDELETION = 0")
    }
    if cloudColumns.contains("ZTRASHED") {
      whereParts.append("note.ZTRASHED = 0")
    }
    if let folderTitleColumn {
      whereParts.append("folder.\(folderTitleColumn) <> 'Recently Deleted'")
    }

    let whereClause = whereParts.joined(separator: " AND ")

    let sql = """
      SELECT
        note.\(noteIdentifierColumn) AS noteIdentifier,
        \(selectTitle) AS title,
        \(selectFolder) AS folderName,
        \(selectSnippet) AS snippet,
        \(selectModified) AS modifiedAt
      FROM \(joinTable) rel
      JOIN ZICCLOUDSYNCINGOBJECT folder ON folder.Z_PK = rel.\(folderKey)
      JOIN ZICCLOUDSYNCINGOBJECT note ON note.Z_PK = rel.\(noteKey)
      WHERE \(whereClause)
      ORDER BY modifiedAt DESC
      """

    return try runQuery(db: db, sql: sql)
  }

  private static func fetchUsingCloudObjectsTable(
    db: OpaquePointer,
    cloudColumns: Set<String>
  ) throws -> [Record] {
    guard
      let noteIdentifierColumn = preferredColumn(
        from: ["ZIDENTIFIER"],
        available: cloudColumns
      )
    else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unsupported Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }
    let noteTitleColumn = preferredColumn(from: noteTitleCandidates, available: cloudColumns)
    let folderTitleColumn = preferredColumn(from: folderTitleCandidates, available: cloudColumns)
    let snippetColumn = preferredColumn(from: snippetCandidates, available: cloudColumns)
    let modifiedColumn = preferredColumn(from: modifiedDateCandidates, available: cloudColumns)

    let hasFolderJoin = cloudColumns.contains("ZFOLDER")
    let selectTitle = noteTitleColumn.map { "note.\($0)" } ?? "\"\""
    let selectFolder =
      hasFolderJoin ? (folderTitleColumn.map { "folder.\($0)" } ?? "\"\"") : "\"\""
    let selectSnippet = snippetColumn.map { "note.\($0)" } ?? "\"\""
    let selectModified = modifiedColumn.map { "note.\($0)" } ?? "0"

    var whereParts: [String] = [
      "note.\(noteIdentifierColumn) IS NOT NULL",
      "note.\(noteIdentifierColumn) <> ''",
    ]

    if let titleColumn = noteTitleColumn {
      whereParts.append("note.\(titleColumn) IS NOT NULL")
      whereParts.append("note.\(titleColumn) <> ''")
    }

    if cloudColumns.contains("ZNOTEDATA") {
      whereParts.append("note.ZNOTEDATA IS NOT NULL")
    }

    if cloudColumns.contains("ZMARKEDFORDELETION") {
      whereParts.append("note.ZMARKEDFORDELETION = 0")
    }
    if cloudColumns.contains("ZTRASHED") {
      whereParts.append("note.ZTRASHED = 0")
    }
    if hasFolderJoin, let folderTitleColumn {
      whereParts.append("COALESCE(folder.\(folderTitleColumn), '') <> 'Recently Deleted'")
    }

    let whereClause = whereParts.joined(separator: " AND ")
    let fromClause: String
    if hasFolderJoin {
      fromClause =
        "FROM ZICCLOUDSYNCINGOBJECT note LEFT JOIN ZICCLOUDSYNCINGOBJECT folder ON folder.Z_PK = note.ZFOLDER"
    } else {
      fromClause = "FROM ZICCLOUDSYNCINGOBJECT note"
    }

    let sql = """
      SELECT
        note.\(noteIdentifierColumn) AS noteIdentifier,
        \(selectTitle) AS title,
        \(selectFolder) AS folderName,
        \(selectSnippet) AS snippet,
        \(selectModified) AS modifiedAt
      \(fromClause)
      WHERE \(whereClause)
      ORDER BY modifiedAt DESC
      """

    return try runQuery(db: db, sql: sql)
  }

  private static func runQuery(db: OpaquePointer, sql: String) throws -> [Record] {
    var statement: OpaquePointer?
    let prepareRc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard prepareRc == SQLITE_OK, let statement else {
      let message = sqlite3_errmsg(db).map(String.init(cString:)) ?? "Query failed."
      throw LoadError(
        title: "Notes Unavailable",
        message: message,
        symbolName: "exclamationmark.triangle.fill"
      )
    }
    defer { sqlite3_finalize(statement) }

    var records: [Record] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let identifier = columnText(statement, index: 0)
      if identifier.isEmpty { continue }
      let title = columnText(statement, index: 1).trimmedOrFallback("Untitled Note")
      let folderName = columnText(statement, index: 2)
      let snippet = columnText(statement, index: 3)
      let modifiedRaw = sqlite3_column_double(statement, 4)
      let modifiedAt = dateFromSQLiteTimestamp(modifiedRaw)

      records.append(
        Record(
          identifier: identifier,
          title: title,
          folderName: folderName,
          snippet: snippet,
          modifiedAt: modifiedAt
        )
      )
    }

    return records
  }

  private static func dateFromSQLiteTimestamp(_ raw: Double) -> Date {
    if raw > 1_200_000_000 {
      return Date(timeIntervalSince1970: raw)
    }
    return Date(timeIntervalSinceReferenceDate: raw)
  }

  private static func tableNames(in db: OpaquePointer) throws -> Set<String> {
    let sql = "SELECT name FROM sqlite_master WHERE type='table'"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unable to read Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }
    defer { sqlite3_finalize(statement) }

    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let name = columnText(statement, index: 0)
      if !name.isEmpty { names.insert(name) }
    }
    return names
  }

  private static func columns(in db: OpaquePointer, table: String) throws -> Set<String> {
    let sql = "PRAGMA table_info('\(table)')"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw LoadError(
        title: "Notes Unavailable",
        message: "Unable to inspect Notes database schema.",
        symbolName: "exclamationmark.triangle.fill"
      )
    }
    defer { sqlite3_finalize(statement) }

    var result: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let name = columnText(statement, index: 1)
      if !name.isEmpty { result.insert(name) }
    }
    return result
  }

  private static func preferredColumn(from candidates: [String], available: Set<String>) -> String?
  {
    candidates.first { available.contains($0) }
  }

  private static func columnText(_ statement: OpaquePointer, index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: cString)
  }
}

extension String {
  fileprivate func trimmedOrFallback(_ fallback: String) -> String {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return fallback }
    return trimmed
  }
}
