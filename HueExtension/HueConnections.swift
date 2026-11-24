import Foundation
import TunaKit

struct HueConnection: Codable, Equatable, Sendable {
  let id: String
  let generation: UUID
  var address: String
  let caPath: String
  var name: String

  init(address: String, id: String, path: String) {
    generation = UUID()
    self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    caPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    name = "Hue Bridge \(self.id.uppercased())"
  }

  func client(key: String) throws -> HueBridge {
    let pem: String
    if caPath.isEmpty {
      pem = hueRootCertificates
    } else {
      guard let contents = try? String(
        contentsOfFile: (caPath as NSString).expandingTildeInPath, encoding: .utf8
      ) else {
        throw HueError.configuration("Check the Hue root CA PEM file for \(name).")
      }
      pem = contents
    }
    return try HueBridge(address: address, id: id, key: key, caPEM: pem)
  }
}

@MainActor
enum HueConnections {
  private static let legacy = CatalogSettingStore(
    catalogIdentifier: Bundle(for: HueExtension.self).bundleIdentifier ?? "de.bjesuiter.tuna.hue"
  )
  private static let legacyKey = CatalogSettingDefinition(
    key: "ApplicationKey", type: .secret, label: "Application key", defaultValue: "",
    description: "The application key from the single-bridge settings."
  )
  private static let recordsKey = legacy.key(for: "Bridges")
  private static let service = "\(legacy.catalogIdentifier).bridges"

  @MainActor
  struct Access {
    let record: @MainActor (String) throws -> HueConnection?
    let key: @MainActor (String) -> String?
    let discover: @MainActor () async throws -> [DiscoveredHueBridge]
    let client: @MainActor (HueConnection, String) throws -> HueBridge
    let saveChanges: @MainActor (HueConnection, HueConnection) throws -> Void
  }

  private static let liveAccess = Access(
    record: { try records()[$0] },
    key: { KeychainStore.stringValue(service: service, account: $0) },
    discover: DiscoveredHueBridge.discover,
    client: { try $0.client(key: $1) },
    saveChanges: saveChanges
  )

  static func records() throws -> [String: HueConnection] {
    if let data = legacy.defaults.data(forKey: recordsKey) {
      return try JSONDecoder().decode([String: HueConnection].self, from: data)
    }

    let record = HueConnection(
      address: legacy.stringValue(for: "BridgeAddress", defaultValue: ""),
      id: legacy.stringValue(for: "BridgeID", defaultValue: ""),
      path: legacy.stringValue(for: "RootCAPath", defaultValue: "")
    )
    guard !record.id.isEmpty, !record.address.isEmpty else { return [:] }
    switch legacy.readSecretValue(for: legacyKey) {
    case .notFound: return [:]
    case .found(let key):
      let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { return [:] }
      let migrated = [record.id: record]
      let data = try JSONEncoder().encode(migrated)
      try storeKey(key, for: record.id)
      legacy.defaults.set(data, forKey: recordsKey)
      return migrated
    case .failed:
      throw HueError.configuration("Could not read the existing Hue key from Keychain.")
    @unknown default:
      throw HueError.configuration("Could not read the existing Hue key from Keychain.")
    }
  }

  static func add(address: String, id: String, key: String, path: String) async throws -> String {
    var record = HueConnection(address: address, id: id, path: path)
    try requireNew(record.id)
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let client = try record.client(key: key)
    async let name = try? client.name()
    _ = try await client.groups()
    if let name = await name, !name.isEmpty { record.name = name }
    try Task.checkCancellation()

    var saved = try records()
    guard saved[record.id] == nil else { throw alreadyConnected }
    saved[record.id] = record
    let data = try JSONEncoder().encode(saved)
    try storeKey(key, for: record.id)
    legacy.defaults.set(data, forKey: recordsKey)
    return record.name
  }

  static func requireNew(_ id: String) throws {
    if try records()[id] != nil { throw alreadyConnected }
  }

  static func disconnect(_ id: String) throws {
    var saved = try records()
    guard saved.removeValue(forKey: id) != nil else { return }
    let data = try JSONEncoder().encode(saved)

    let legacyID = legacy.stringValue(for: "BridgeID", defaultValue: "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if legacyID == id {
      legacy.deleteSecretValue(for: legacyKey)
      guard legacy.readSecretValue(for: legacyKey) == .notFound else {
        throw HueError.configuration("Could not remove the legacy Hue application key from Keychain.")
      }
    }
    guard KeychainStore.delete(service: service, account: id)
      || KeychainStore.readString(service: service, account: id) == .notFound else {
      throw HueError.configuration("Could not remove the Hue application key from Keychain.")
    }
    legacy.defaults.set(data, forKey: recordsKey)
  }

  static func use<T: Sendable>(
    _ id: String, access: Access = liveAccess, operation: (HueBridge) async throws -> T
  ) async throws -> T {
    guard let record = try access.record(id) else { throw HueError.disconnected }
    guard let key = access.key(id) else {
      throw HueError.configuration("Could not read the Hue key for \(record.name) from Keychain.")
    }
    let client = try access.client(record, key)
    do {
      return try await operation(client)
    } catch let error as URLError {
      try Task.checkCancellation()
      guard let discovered = try? await access.discover(),
            let match = discovered.first(where: {
              $0.id.lowercased() == id && $0.internalipaddress != record.address
            }) else { throw error }
      try Task.checkCancellation()
      guard let current = try access.record(id), current.generation == record.generation else {
        throw HueError.disconnected
      }
      // A concurrent request may already have found a new address.
      var updated = current
      if current.address == record.address { updated.address = match.internalipaddress }
      guard let currentKey = access.key(id) else {
        throw HueError.disconnected
      }
      let result = try await operation(access.client(updated, currentKey))
      try Task.checkCancellation()
      if updated.address != current.address, var latest = try access.record(id),
         latest.generation == current.generation, latest.address == current.address {
        let previous = latest
        latest.address = updated.address
        try access.saveChanges(previous, latest)
      }
      return result
    }
  }

  static func updateName(_ name: String, for id: String, generation: UUID) throws {
    guard !name.isEmpty, let record = try records()[id], record.generation == generation else { return }
    var updated = record
    updated.name = name
    try saveChanges(from: record, to: updated)
  }

  private static let alreadyConnected = HueError.configuration(
    "This Hue bridge is already connected. Use Manage Hue Bridges to disconnect it first."
  )

  private static func saveChanges(from original: HueConnection, to updated: HueConnection) throws {
    guard original != updated else { return }
    var saved = try records()
    guard saved[original.id] == original else { return }
    saved[updated.id] = updated
    legacy.defaults.set(try JSONEncoder().encode(saved), forKey: recordsKey)
  }

  private static func storeKey(_ key: String, for id: String) throws {
    guard KeychainStore.setString(key, service: service, account: id) else {
      throw HueError.configuration("Could not save the Hue application key in Keychain.")
    }
  }
}
