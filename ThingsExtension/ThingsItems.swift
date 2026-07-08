import AppKit
import Foundation
import TunaKit

final class ThingsListItem: CatalogItem, CopyRepresentationProviding,
  TextValueProviding, @unchecked Sendable
{
  let listID: String?
  let query: String?
  private let symbolName: String
  private let detailText: String?
  private var previewSymbol: CatalogItemPreview {
    CatalogItemPreview.systemSymbol(symbolName)
  }

  init(
    title: String, listID: String? = nil, query: String? = nil, symbolName: String,
    detail: String? = nil
  ) {
    self.listID = listID
    self.query = query
    self.symbolName = symbolName
    self.detailText = detail
    super.init(
      id: Self.identifier(title: title, listID: listID, query: query),
      title: title,
      type: .entity)
    typeID = .thingsList
  }

  private static func identifier(title: String, listID: String?, query: String?) -> String {
    if let listID {
      return "things.list.\(listID)"
    }
    if let query {
      return "things.query.\(query)"
    }
    return "things.list.\(title)"
  }

  var textValue: String {
    thingsURLString ?? id
  }

  var copyRepresentation: String? {
    textValue
  }

  override var detail: String? { detailText }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview { previewSymbol }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview { previewSymbol }

  private var thingsURLString: String? {
    ThingsURLBuilder.showURL(listID: listID, query: query)?.absoluteString
  }
}

extension TypeID {
  static let thingsList = TypeID("com.tuna.type.things-list")
}
