import AppKit
import Foundation
import TunaKit

/// Two search roots, `pass` and `otp`. Typing contacts nothing; Strongbox is asked only on Enter.
@MainActor
public final class StrongboxCatalog: Catalog {
  public let identifier: String
  public let name: String
  public let objects: [CatalogItem]

  public init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    objects = [
      Self.root(
        title: "Search Strongbox Passwords", id: "strongbox.search.root",
        detail: "Type an entry name · copy its password, username, or one-time code",
        first: .password),
      Self.root(
        title: "OTP from Strongbox", id: "strongbox.otp.root",
        detail: "Type an entry name · copy its one-time code", first: .totp),
    ]
  }

  public func scan() async { reportScanFinished() }

  private static func root(title: String, id: String, detail: String, first: StrongboxField)
    -> ScopedSearchBrowseCatalogItem
  {
    ScopedSearchBrowseCatalogItem(
      title: title, id: id, detail: detail,
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
      loadChildren: { await StrongboxRuntime.vaultRows() },
      searchHandler: { await StrongboxRuntime.queryItems($0, first: first) }
    )
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

final class StrongboxQueryItem: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  let query: String
  let field: StrongboxField

  init(_ query: String, field: StrongboxField) {
    self.query = query
    self.field = field
    super.init(
      id: "strongbox.find.\(field.rawValue)", title: "Copy \(field.label) for “\(query)”", path: nil)
    typeID = .strongboxQuery
  }

  override var detail: String? { "Enter asks Strongbox to unlock if needed, then finds and copies" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(field.symbolName, tintColor: .systemTeal)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    action.id == StrongboxActionsCatalog.find
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
