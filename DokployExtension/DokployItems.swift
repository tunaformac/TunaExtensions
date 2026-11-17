import AppKit
import Foundation
import TunaKit

/// A Dokploy application or compose service. Carries the connection it came from so actions
/// can call the right server.
final class DokployServiceItem: CatalogEntity, @unchecked Sendable {
  let service: DokployService
  let connectionRecordID: String
  private let detailText: String

  init(service: DokployService, connection: DokployConnection, showsConnectionName: Bool) {
    self.service = service
    self.connectionRecordID = connection.recordID
    var parts: [String] = [service.projectName]
    if let environment = service.environmentName { parts.append(environment) }
    parts.append(service.kind.displayName)
    if let status = service.statusLabel { parts.append(status) }
    self.detailText = parts.joined(separator: " · ")
    let title = showsConnectionName ? "\(connection.displayName): \(service.name)" : service.name
    super.init(id: service.itemID, title: title, path: nil)
    typeID = service.kind == .application ? .dokployApplication : .dokployCompose
  }

  override var detail: String? { detailText }

  override var searchKeys: [String] { [service.projectName] }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol(Self.symbolName(for: service.kind), tintColor: statusColor)
  }

  static func symbolName(for kind: DokployServiceKind) -> String {
    switch kind {
    case .application: "shippingbox"
    case .compose: "square.stack.3d.up"
    }
  }

  private var statusColor: NSColor? {
    switch service.status {
    case "done": .systemGreen
    case "running": .systemBlue
    case "error": .systemRed
    default: nil
    }
  }
}

enum DokployMessages {
  static func notConfigured() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Configure Dokploy",
      message: "Add your Dokploy URL and API key in Settings > Extensions > Dokploy.",
      symbolName: "gearshape",
      tintColor: .systemOrange
    )
  }

  static func incompleteConnection() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Dokploy connection incomplete",
      message: "Check that the connection has a valid http(s) URL and an API key.",
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func failure(_ error: Error, connection: DokployConnection, showsConnectionName: Bool)
    -> CatalogMessageItem
  {
    let apiError = error as? DokployAPIError
    let title = apiError?.title ?? "Dokploy request failed"
    return CatalogMessageItem(
      title: showsConnectionName ? "\(connection.displayName): \(title)" : title,
      message: apiError?.errorDescription ?? "Could not load services from Dokploy.",
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func empty() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "No Dokploy services",
      message: "The connected Dokploy servers have no applications or compose services.",
      symbolName: "shippingbox",
      tintColor: .systemGray
    )
  }
}
