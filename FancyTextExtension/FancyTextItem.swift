import Foundation
import TunaKit

final class FancyTextItem: CatalogItem, TextValueProviding, @unchecked Sendable {
  let textValue: String
  let styleName: String

  init(text: String, styleName: String) {
    textValue = text
    self.styleName = styleName
    super.init(id: "fancy-text:\(styleName):\(text)", title: text, type: .entity)
    typeID = .textSnippet
  }

  override var detail: String? { styleName }
  override var searchKeys: [String] { [title, styleName] }
}
