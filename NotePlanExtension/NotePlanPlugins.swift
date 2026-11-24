import AppKit
import Foundation
import TunaKit

/// One runnable command of an installed NotePlan plugin.
struct NotePlanPluginCommandRecord: Codable, Equatable, Sendable {
  let pluginID: String
  let pluginName: String
  let name: String
  let description: String
}

/// Reads the installed plugins through NotePlan's `listInstalledPlugins` Apple Events command.
/// Like the note list, it never touches NotePlan's storage and never launches NotePlan; the last
/// answer is cached so commands stay searchable while NotePlan is closed.
enum NotePlanPluginProvider {
  nonisolated(unsafe) static var cacheURLOverride: URL?

  static func loadCommands() -> Result<[NotePlanPluginCommandRecord], NotePlanProviderError> {
    guard let bundleIdentifier = NotePlanProvider.runningBundleIdentifier() else {
      return .success(cachedCommands() ?? [])
    }

    do {
      let output = try NotePlanProvider.run(script(bundleIdentifier: bundleIdentifier))
      let commands = try parse(output)
      if commands.isEmpty, let cached = cachedCommands(), !cached.isEmpty {
        return .success(cached)
      }
      storeCommands(commands)
      return .success(commands)
    } catch let error as NotePlanProviderError {
      if error != .automationDenied, let cached = cachedCommands(), !cached.isEmpty {
        return .success(cached)
      }
      return .failure(error)
    } catch {
      return .failure(.failed(error.localizedDescription))
    }
  }

  static func script(bundleIdentifier: String) -> String {
    """
    tell application id "\(bundleIdentifier)"
      return listInstalledPlugins
    end tell
    """
  }

  /// Keeps enabled, visible plugins and their visible commands, sorted by plugin and command name.
  static func parse(_ output: String) throws -> [NotePlanPluginCommandRecord] {
    struct Plugin: Decodable {
      struct Command: Decodable {
        let name: String
        let description: String?
        let hidden: Bool?
      }
      let id: String
      let name: String
      let isEnabled: Bool?
      let hidden: Bool?
      let commands: [Command]?
    }

    let plugins: [Plugin]
    do {
      plugins = try JSONDecoder().decode([Plugin].self, from: Data(output.utf8))
    } catch {
      throw NotePlanProviderError.failed("NotePlan returned an unexpected plugin list.")
    }

    return plugins
      .filter { $0.isEnabled != false && $0.hidden != true }
      .flatMap { plugin in
        (plugin.commands ?? [])
          .filter { $0.hidden != true && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
          .map {
            NotePlanPluginCommandRecord(
              pluginID: plugin.id,
              pluginName: plugin.name,
              name: $0.name,
              description: $0.description ?? "")
          }
      }
      .sorted {
        ($0.pluginName.localizedLowercase, $0.name.localizedLowercase)
          < ($1.pluginName.localizedLowercase, $1.name.localizedLowercase)
      }
  }

  // MARK: Cache

  static var cacheURL: URL? {
    if let cacheURLOverride { return cacheURLOverride }
    return NotePlanProvider.cacheURL?.deletingLastPathComponent()
      .appendingPathComponent("plugins.json")
  }

  static func cachedCommands() -> [NotePlanPluginCommandRecord]? {
    guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode([NotePlanPluginCommandRecord].self, from: data)
  }

  static func storeCommands(_ commands: [NotePlanPluginCommandRecord]) {
    guard let cacheURL, let data = try? JSONEncoder().encode(commands) else { return }
    try? FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }
}

final class NotePlanPluginCommandItem: CatalogItem, @unchecked Sendable {
  let record: NotePlanPluginCommandRecord

  init(record: NotePlanPluginCommandRecord) {
    self.record = record
    super.init(
      id: "noteplan.plugin.\(record.pluginID).\(record.name)", title: record.name, type: .entity)
    typeID = .notePlanPluginCommand
  }

  override var searchText: String { "\(title) \(record.pluginName)" }

  override var detail: String? {
    let description = record.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? record.pluginName : "\(record.pluginName) • \(description)"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("puzzlepiece.extension", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("puzzlepiece.extension", tintColor: .secondaryLabelColor)
  }
}

/// Commands of the installed NotePlan plugins.
@MainActor
public final class NotePlanPluginsCatalog: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private let itemsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }
    return itemsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func releaseRetainedState() {
    itemsStore.value = []
    messageStore.value = nil
  }

  public func scan() async {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      messageStore.value = nil
      itemsStore.value = []
      reportScanFinished()
      return
    }

    let result = await Task.detached(priority: .utility) {
      NotePlanPluginProvider.loadCommands()
    }.value

    switch result {
    case .success(let commands):
      messageStore.value = nil
      itemsStore.value = commands.map(NotePlanPluginCommandItem.init(record:))
    case .failure(let error):
      itemsStore.value = []
      messageStore.value = [
        CatalogMessageItem(
          title: error.title,
          message: error.errorDescription ?? "",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange
        )
      ]
    }

    reportScanFinished()
  }
}

extension TypeID {
  static let notePlanPluginCommand = TypeID("com.tuna.type.noteplan-plugin-command")
}
