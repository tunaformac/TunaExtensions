import AppKit
import Foundation
import TunaKit

/// Password, Username and OTP from Strongbox. Each is a subject whose only action asks for the
/// entry name in the third pane, so typing contacts nothing and Strongbox is asked only on Enter.
@MainActor
public final class StrongboxCatalog: Catalog {
  public let identifier: String
  public let name: String
  public let objects: [CatalogItem]

  public init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    objects = StrongboxField.allCases.map(StrongboxFieldCommandItem.init)
  }

  public func scan() async { reportScanFinished() }
}

/// Strongbox → Right Arrow: the MCP vaults, for choosing the one searched. Vault names are read
/// only when this is entered; no vault is unlocked and no entry is read.
@MainActor
public final class StrongboxVaultsCatalog: Catalog {
  public let identifier: String
  public let name: String
  private let browseItem: DeferredBrowseCatalogItem

  public var objects: [CatalogItem] { [browseItem] }

  public init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    let identifier = definition.identifier
    // Choosing a vault reloads the list on the next visit, so the vault in use moves to the top.
    let reloader = Reloader()
    browseItem = DeferredBrowseCatalogItem(
      title: "Strongbox Vaults",
      id: "strongbox.vaults.browse",
      detail: "Choose the vault Strongbox searches",
      catalogIcon: .init(symbolName: "lock.shield", color: .teal),
      loadingItemProvider: {
        CatalogLoadingItem(message: "Reading opted-in Strongbox vault names…")
      },
      errorItemProvider: { error in
        CatalogMessageItem(
          title: "Strongbox Unavailable",
          message: StrongboxRuntime.safeError(error),
          symbolName: "exclamationmark.shield",
          tintColor: .systemOrange
        )
      },
      didLoad: {
        NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
      },
      loadChildren: {
        try await StrongboxRuntime.vaultRows(onChoose: { await reloader.reset() })
      }
    )
    reloader.item = browseItem
  }

  @MainActor
  private final class Reloader {
    weak var item: DeferredBrowseCatalogItem?
    func reset() { item?.reset() }
  }

  /// Refresh reads the vault names again.
  public func scan() async {
    browseItem.reset()
    reportScanFinished()
  }
}

/// "Password from Strongbox" and its siblings: the subject when you start with the command and
/// type the entry name second. The IDs are those of 0.1's search roots, so Tuna's learned
/// abbreviations (`pass`, `otp`) keep finding them.
final class StrongboxFieldCommandItem: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  let field: StrongboxField

  init(_ field: StrongboxField) {
    self.field = field
    super.init(id: Self.id(for: field), title: "\(field.name) from Strongbox", path: nil)
    typeID = .searchCatalogEntry
  }

  static func id(for field: StrongboxField) -> String {
    switch field {
    case .password: return "strongbox.search.root"
    case .username: return "strongbox.username.root"
    case .totp: return "strongbox.otp.root"
    }
  }

  override var detail: String? { "Type an entry name · copy its \(field.label)" }

  override var searchKeys: [String] {
    switch field {
    case .password: return [title, "pass", "Strongbox Password"]
    case .username: return [title, "user", "email", "Strongbox Username"]
    case .totp: return [title, "otp", "one-time code", "2FA", "Strongbox OTP"]
    }
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: field.symbolName, color: .teal, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    catalogIdentifier == StrongboxExtension.actionsCatalogIdentifier
      && action.id == StrongboxActionsCatalog.copyFieldID(field)
  }
}

final class StrongboxEntryItem: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  let entry: StrongboxEntry
  let field: StrongboxField

  init(_ entry: StrongboxEntry, field: StrongboxField) {
    self.entry = entry
    self.field = field
    super.init(
      id: "strongbox.entry.\(field.rawValue).\(entry.databaseID).\(entry.id)", title: entry.title,
      path: nil)
    typeID = .strongboxEntry
  }

  override var detail: String? {
    ["Copy \(field.label)", entry.username, entry.databaseName].filter { !$0.isEmpty }
      .joined(separator: " · ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(field.symbolName, tintColor: .systemTeal)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    action.id == StrongboxActionsCatalog.copy
      && catalogIdentifier == StrongboxExtension.actionsCatalogIdentifier
  }
}

final class StrongboxCommand: CatalogEntity, Runnable, @unchecked Sendable {
  let headlessEligibility: CommandHeadlessEligibility = .requiresInterface
  let executionPolicy: CommandExecutionPolicy
  private let subtitle: String
  private let operation: @MainActor @Sendable () async -> ActionResult

  init(
    id: String, title: String, detail: String,
    executionPolicy: CommandExecutionPolicy = .resultDriven,
    operation: @escaping @MainActor @Sendable () async -> ActionResult
  ) {
    self.executionPolicy = executionPolicy
    subtitle = detail
    self.operation = operation
    super.init(id: id, title: title, path: nil)
    typeID = .command
  }

  override var detail: String? { subtitle }
  override func preview(maxDimension: CGFloat) -> CatalogItemPreview { .systemSymbol("lock.shield") }
  func run() async -> ActionResult { await operation() }
}

extension StrongboxField {
  var symbolName: String {
    switch self {
    case .password: return "key"
    case .username: return "person"
    case .totp: return "clock"
    }
  }
}
