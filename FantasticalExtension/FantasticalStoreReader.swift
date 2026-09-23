import Foundation
import OSLog
import SQLite3

/// Fantastical keeps the accounts it syncs itself (Google Tasks, Todoist, CalDAV) in its own
/// store, and its helper reads that store but never says whether a task is done. The index table
/// carries the flag per row, and the row's archive carries the rest.
struct FantasticalStoreReader: Sendable {
  static let log = Logger(subsystem: "com.brnbw.tuna.plugins.fantastical", category: "store")

  static let databaseURL = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/Group Containers/85C27NK92C.com.flexibits.fantastical2.mac/Database/Fantastical-8.fcdata")

  enum ReadError: LocalizedError {
    case cannotOpen(String)
    case badStatement(String)

    var errorDescription: String? {
      switch self {
      case .cannotOpen(let detail): return "Fantastical's database could not be opened: \(detail)"
      case .badStatement(let detail): return "Fantastical's database could not be read: \(detail)"
      }
    }
  }

  let url: URL

  init(url: URL = FantasticalStoreReader.databaseURL) {
    self.url = url
  }

  var isAvailable: Bool { FileManager.default.isReadableFile(atPath: url.path) }

  func openTasks(in listID: String) throws -> [FantasticalAgendaItem] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
      let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
      sqlite3_close(handle)
      throw ReadError.cannotOpen(detail)
    }
    defer { sqlite3_close(db) }

    let sql = """
      SELECT d.key, d.data FROM database2 d
      JOIN secondaryIndex_index_calendarItems i ON i.rowid = d.rowid
      WHERE d.collection = ? AND i.completed = 0 AND (i.hidden IS NULL OR i.hidden = 0)
      ORDER BY d.rowid
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let query = statement else {
      throw ReadError.badStatement(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(query) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(query, 1, "calendarItems-\(listID)", -1, transient)

    var items: [FantasticalAgendaItem] = []
    while sqlite3_step(query) == SQLITE_ROW {
      guard let keyText = sqlite3_column_text(query, 0) else { continue }
      let key = String(cString: keyText)
      let length = Int(sqlite3_column_bytes(query, 1))
      guard length > 0, let bytes = sqlite3_column_blob(query, 1) else { continue }
      guard let task = FantasticalArchivedTask.decode(from: Data(bytes: bytes, count: length)), !task.completed
      else { continue }
      items.append(
        FantasticalAgendaItem(
          id: FantasticalTaskID.make(listID: listID, key: key), title: task.title, calendarID: listID,
          start: task.dueDate, end: nil, location: nil, priority: task.priority))
    }
    return items
  }
}

/// Stands in for Fantastical's `FBTask` while its archive is opened: only the keys named here are
/// read, so the rest of the object never has to be understood.
final class FantasticalArchivedTask: NSObject, NSSecureCoding {
  static let supportsSecureCoding = true
  static let archivedClassName = "FBTask"

  let title: String
  let priority: Int
  let dueDate: Date?
  let completed: Bool

  init(title: String, priority: Int, dueDate: Date?, completed: Bool) {
    self.title = title
    self.priority = priority
    self.dueDate = dueDate
    self.completed = completed
  }

  required init?(coder: NSCoder) {
    title = coder.decodeObject(of: NSString.self, forKey: "title") as String? ?? ""
    priority = coder.decodeInteger(forKey: "priority")
    dueDate = coder.decodeObject(of: NSDate.self, forKey: "dueDate") as Date?
    completed = coder.decodeBool(forKey: "completed")
  }

  func encode(with coder: NSCoder) {
    coder.encode(title as NSString, forKey: "title")
    coder.encode(priority, forKey: "priority")
    if let dueDate { coder.encode(dueDate as NSDate, forKey: "dueDate") }
    coder.encode(completed, forKey: "completed")
  }

  static func decode(from data: Data) -> FantasticalArchivedTask? {
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    unarchiver.setClass(FantasticalArchivedTask.self, forClassName: archivedClassName)
    defer { unarchiver.finishDecoding() }
    return unarchiver.decodeObject(of: FantasticalArchivedTask.self, forKey: NSKeyedArchiveRootObjectKey)
  }
}
