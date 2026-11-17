import Foundation

enum StrongboxError: Error, LocalizedError, Sendable, Equatable {
  case unavailable, untrustedHelper, invalidResponse, timedOut, notPaired, disabled, disconnected
  case denied, locked, unavailableEntry, busy, clipboardWriteFailed
  case unexpectedReveal(shape: String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Open Strongbox and enable its local MCP integration. Strongbox must be installed in /Applications or /Applications/Setapp."
    case .untrustedHelper:
      return "The Strongbox helper could not be verified as signed by Strongbox. No helper was launched."
    case .invalidResponse:
      return "Strongbox returned an unexpected response. No response contents were logged."
    case .timedOut:
      return "Strongbox did not respond in time. Check its approval dialogs."
    case .disconnected:
      return "The Strongbox helper disconnected. Check that Strongbox is running, MCP is enabled, and Tuna is paired as a signed MCP host."
    case .notPaired:
      return "Approve Tuna in Strongbox → Settings → Extensions → Paired MCP Hosts. Enable access only for the vaults you want to search."
    case .disabled:
      return "Enable MCP in Strongbox → Settings → Extensions and opt in the desired AutoFill-enabled vaults."
    case .denied:
      return "Strongbox didn't allow this. If you cancelled its prompt, try again. Otherwise check Tuna under Strongbox → Settings → Extensions → Paired MCP Hosts, and the vault under Vault Access."
    case .locked:
      return "This vault is locked. Press Enter again to request access through Strongbox."
    case .unavailableEntry:
      return "This entry has no such value, or it uses a field reference, which MCP doesn't expand."
    case .busy:
      return "Another Strongbox action is in progress."
    case .clipboardWriteFailed:
      return "The value could not be written to the clipboard."
    case let .unexpectedReveal(shape):
      return "Strongbox's reveal response had an unexpected format, so nothing was copied. Structure, without values: " + shape
    }
  }
}

enum StrongboxField: String, CaseIterable, Sendable {
  case password, username, totp

  var label: String {
    switch self {
    case .password: return "password"
    case .username: return "username or email"
    case .totp: return "one-time code"
    }
  }
}

struct StrongboxDatabase: Decodable, Sendable, Identifiable {
  let id: String
  let name: String
  let locked: Bool

  enum CodingKeys: String, CodingKey {
    case id = "database_id", name = "database_name", locked
  }

  /// A remembered vault that is no longer listed asks for a new choice, even if one vault is left,
  /// so a search never moves to another vault on its own.
  static func selectedForSearch(_ databases: [StrongboxDatabase], preferredID: String?) -> StrongboxDatabase? {
    guard let preferredID else { return databases.count == 1 ? databases[0] : nil }
    guard let identifier = UUID(uuidString: preferredID) else { return nil }
    return databases.first { UUID(uuidString: $0.id) == identifier }
  }
}

struct StrongboxEntry: Decodable, Sendable, Identifiable {
  let id: String
  let databaseID: String
  let databaseName: String
  let title: String
  let username: String
  let availableFields: [String]

  enum CodingKeys: String, CodingKey {
    case id = "credential_id", databaseID = "database_id", databaseName = "database_name"
    case title, username, availableFields = "available_fields"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    databaseID = try container.decode(String.self, forKey: .databaseID)
    databaseName = try container.decode(String.self, forKey: .databaseName)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Entry"
    username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    availableFields = try container.decodeIfPresent([String].self, forKey: .availableFields) ?? []
  }

  /// The exact name of a custom Email field, for entries that keep the login there instead of in the username.
  var emailField: String? {
    availableFields.first { $0.caseInsensitiveCompare("custom:email") == .orderedSame }
  }

  /// Whether search listed this field. An empty list says nothing, so Strongbox is asked anyway.
  func mayHave(_ field: String) -> Bool {
    availableFields.isEmpty || availableFields.contains { $0.caseInsensitiveCompare(field) == .orderedSame }
  }

  /// The entry a query unambiguously names: its only exact title match, or the only result. Never a guess.
  /// A full list may have been cut off before another entry with the same title, so it is never trusted.
  static func directMatch(in entries: [StrongboxEntry], query: String) -> StrongboxEntry? {
    guard entries.count < StrongboxClient.searchLimit else { return nil }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let exact = entries.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
    if exact.count == 1 { return exact[0] }
    return exact.isEmpty && entries.count == 1 ? entries[0] : nil
  }
}

struct DatabaseList: Decodable { let databases: [StrongboxDatabase] }
struct EntryList: Decodable { let matches: [StrongboxEntry] }

enum JSONValue: Codable, Sendable {
  case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { throw StrongboxError.invalidResponse }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  subscript(_ key: String) -> JSONValue? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }

  var string: String? { if case .string(let value) = self { return value }; return nil }
  var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
  var boolean: Bool? { if case .bool(let value) = self { return value }; return nil }
  var number: Double? { if case .number(let value) = self { return value }; return nil }

  func decoded<Value: Decodable>(as type: Value.Type) throws -> Value {
    do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
    catch { throw StrongboxError.invalidResponse }
  }
}

extension JSONValue {
  /// `reveal_credential` publishes no output schema, so this accepts the plausible layouts and fails closed.
  func revealedValue(_ name: String) -> String? {
    let root = self["revealed_credential"] ?? self
    let fields = root["fields"]
    return fields?[name]?.string ?? root[name]?.string ?? fields?[name]?["value"]?.string
      ?? fields?.array?.first {
        ($0["name"] ?? $0["field"] ?? $0["key"])?.string == name
      }?["value"]?.string
  }

  func listsUnavailable(_ name: String) -> Bool {
    let root = self["revealed_credential"] ?? self
    return root["unavailable_fields"]?.array?.contains { $0.string == name } ?? false
  }

  /// Keys Strongbox's own layout uses. Other keys, such as custom field names, are only counted.
  private static let knownKeys: Set<String> = [
    "revealed_credential", "fields", "unavailable_fields", "value", "name", "field", "key",
    "password", "username", "totp", "credential_id", "database_id", "title",
  ]

  /// Known keys and types only, so an unexpected response can be diagnosed without exposing a value or field name.
  var shape: String {
    switch self {
    case let .object(values):
      let known = values.keys.filter(Self.knownKeys.contains).sorted().map { $0 + ":" + values[$0]!.shape }
      let others = values.count - known.count
      return "{" + (known + (others > 0 ? ["\(others) other"] : [])).joined(separator: ",") + "}"
    case let .array(values): return "[" + (values.first?.shape ?? "") + "]"
    case .string: return "string"
    case .number: return "number"
    case .bool: return "bool"
    case .null: return "null"
    }
  }
}
