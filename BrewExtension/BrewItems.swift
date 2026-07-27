import AppKit
import Foundation
import TunaKit

final class BrewMetaItem: CatalogEntity, ActionFilteringProviding, CatalogHierarchyNode,
  ScopedCatalogSearchProviding, @unchecked Sendable
{
  private let detailText: String

  init(title: String, detail: String) {
    self.detailText = detail
    super.init(id: title, title: title, path: nil)
    typeID = .brewMeta
  }

  override var detail: String? { detailText }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.catalogIcon(symbolName: "mug", color: .orange, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    // "search" is the scoped-search action from Tuna's common actions catalog.
    action.id == "search" || BrewActionsCatalog.metaActionIDs.contains(action.id)
  }

  func hierarchyChildren() -> [CatalogItem] { [] }

  var scopedSearchConfiguration: ScopedSearchConfiguration {
    ScopedSearchConfiguration(debounce: .milliseconds(200), searchOnChange: true)
  }

  func scopedSearch(query: String) async throws -> [CatalogItem] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    do {
      return
        (try await BrewDataStore.shared.search(
          query: trimmedQuery,
          customBrewPath: BrewSettings.customBrewPath
        )).map(BrewPackageItem.init)
    } catch {
      return [
        CatalogMessageItem(
          title: "Homebrew Unavailable",
          message: error.localizedDescription,
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange
        )
      ]
    }
  }
}

enum BrewPackageKind: String, Sendable {
  case formula
  case cask

  var label: String {
    switch self {
    case .formula: "Formula"
    case .cask: "Cask"
    }
  }
}

struct BrewPackageRecord: Hashable, Sendable {
  let name: String
  let kind: BrewPackageKind
  var installedVersion: String?
  var latestVersion: String?
  var isOutdated = false

  var isInstalled: Bool { installedVersion != nil }
}

final class BrewPackageItem: CatalogItem, ActionFilteringProviding, @unchecked Sendable {
  let record: BrewPackageRecord

  var packageName: String { record.name }
  var kind: BrewPackageKind { record.kind }
  var isInstalled: Bool { record.isInstalled }
  var isOutdated: Bool { record.isOutdated }

  override var detail: String? {
    var parts = [record.kind.label]
    parts.append(record.installedVersion.map { "Installed \($0)" } ?? "Not installed")
    if record.isOutdated, let latestVersion = record.latestVersion {
      parts.append("Latest \(latestVersion)")
    }
    return parts.joined(separator: " • ")
  }

  override var searchText: String { [record.name, record.kind.label].joined(separator: " ") }

  init(record: BrewPackageRecord) {
    self.record = record
    super.init(id: record.name, title: record.name, type: .entity)
    typeID = Self.typeID(for: record)
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    let symbolName =
      switch (record.kind, record.isOutdated, record.isInstalled) {
      case (_, true, _): "arrow.triangle.2.circlepath.circle"
      case (.cask, _, true): "shippingbox.fill"
      case (.cask, _, false): "shippingbox"
      case (.formula, _, true): "pills.fill"
      case (.formula, _, false): "pills"
      }
    return CatalogItemPreview.systemSymbol(symbolName, tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier _: String?) -> Bool {
    BrewActionsCatalog.packageActionIDs.contains(action.id)
  }

  private static func typeID(for record: BrewPackageRecord) -> TypeID {
    if record.isOutdated { return .brewPackageOutdated }
    if record.isInstalled { return .brewPackageInstalled }
    return .brewPackageAvailable
  }
}

extension TypeID {
  static let brewMeta = TypeID("com.tuna.type.brew-meta")
  static let brewPackage = TypeID("com.tuna.type.brew-package")
  static let brewPackageAvailable = TypeID("com.tuna.type.brew-package-available")
  static let brewPackageInstalled = TypeID("com.tuna.type.brew-package-installed")
  static let brewPackageOutdated = TypeID("com.tuna.type.brew-package-outdated")
}
