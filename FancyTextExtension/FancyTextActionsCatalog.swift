import Foundation
import TunaKit

public final class FancyTextActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = [Self.makeFancyTextAction()]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeFancyTextAction() -> CatalogAction {
    let action = PredicateAwareAction(id: "generate", title: "Make Fancy Text") { subject, _ in
      guard let text = subject.textInputValue(), !text.isEmpty else {
        return .failure("Select or type some text first")
      }

      do {
        let items = try FancyTextFont.productionFonts.map { font in
          FancyTextItem(text: font.convert(text), styleName: font.name)
        }
        return .results(items)
      } catch {
        return .failure("Fancy Text styles could not be loaded")
      }
    }
    action.systemSymbolName = "wand.and.sparkles"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = {
      $0?.textInputValue()?.isEmpty == false
    }
    action.executionPolicy = .keepVisible
    return action
  }
}
