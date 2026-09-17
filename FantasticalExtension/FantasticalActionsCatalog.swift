import AppKit
import Foundation
import TunaKit

public final class FantasticalActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions() + Self.appActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }
}

extension FantasticalActionsCatalog {
  static let textActionIDs = [
    "add-to-fantastical", "add-task-to-fantastical", "search-fantastical", "show-date-in-fantastical",
  ]
  static let appActionIDs = ["new-event", "new-task", "search"]

  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let show = PredicateAwareAction(
      id: FantasticalIdentifiers.showAction, title: "Show in Fantastical"
    ) { subject, _ in
      guard let item = subject as? FantasticalDestinationItem else {
        return .failure("No Fantastical view selected")
      }
      return FantasticalActions.open(
        url: FantasticalURLBuilder.showURL(for: item.destination),
        failure: "Invalid Fantastical URL")
    }
    show.systemSymbolName = "arrow.up.right.square"
    show.supportedSubjectTypes = [.fantasticalDestination]
    show.subjectPredicate = { $0 is FantasticalDestinationItem }
    items.append(show)

    items.append(
      makeTextAction(
        id: "add-to-fantastical", title: "Add to Fantastical", symbolName: "plus.circle",
        failure: "Nothing to add", activates: { !FantasticalSettings.addImmediately }
      ) { text in
        FantasticalURLBuilder.parseURL(
          sentence: text, task: false,
          addImmediately: FantasticalSettings.addImmediately,
          miniWindow: FantasticalSettings.useMiniWindow)
      })

    items.append(
      makeTextAction(
        id: "add-task-to-fantastical", title: "Add Task to Fantastical",
        symbolName: "checkmark.circle", failure: "Nothing to add",
        activates: { !FantasticalSettings.addImmediately }
      ) { text in
        FantasticalURLBuilder.parseURL(
          sentence: text, task: true,
          addImmediately: FantasticalSettings.addImmediately,
          miniWindow: FantasticalSettings.useMiniWindow)
      })

    items.append(
      makeTextAction(
        id: "search-fantastical", title: "Search Fantastical", symbolName: "magnifyingglass",
        failure: "Missing search query"
      ) { text in
        FantasticalURLBuilder.searchURL(query: text, miniWindow: FantasticalSettings.useMiniWindow)
      })

    let showDate = makeTextAction(
      id: "show-date-in-fantastical", title: "Show Date in Fantastical", symbolName: "calendar",
      failure: "Text is not a date"
    ) { text in
      FantasticalURLBuilder.parseDate(from: text).flatMap { FantasticalURLBuilder.dateURL($0) }
    }
    showDate.subjectPredicate = { subject in
      guard let text = FantasticalURLBuilder.textValue(for: subject) else { return false }
      return FantasticalURLBuilder.parseDate(from: text) != nil
    }
    items.append(showDate)

    return items
  }

  static func appActions() -> [CatalogAction] {
    [
      makeAppTextAction(
        id: "new-event", title: "New Event", symbolName: "plus.circle",
        failure: "Missing event text", activates: { !FantasticalSettings.addImmediately }
      ) { text in
        FantasticalURLBuilder.parseURL(
          sentence: text, task: false,
          addImmediately: FantasticalSettings.addImmediately,
          miniWindow: FantasticalSettings.useMiniWindow)
      },
      makeAppTextAction(
        id: "new-task", title: "New Task", symbolName: "checkmark.circle",
        failure: "Missing task text", activates: { !FantasticalSettings.addImmediately }
      ) { text in
        FantasticalURLBuilder.parseURL(
          sentence: text, task: true,
          addImmediately: FantasticalSettings.addImmediately,
          miniWindow: FantasticalSettings.useMiniWindow)
      },
      makeAppTextAction(
        id: "search", title: "Search", symbolName: "magnifyingglass",
        failure: "Missing search query"
      ) { text in
        FantasticalURLBuilder.searchURL(query: text, miniWindow: FantasticalSettings.useMiniWindow)
      },
    ]
  }

  private static func makeTextAction(
    id: String,
    title: String,
    symbolName: String,
    failure: String,
    activates: @escaping () -> Bool = { true },
    url: @escaping (String) -> URL?
  ) -> PredicateAwareAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard let text = FantasticalURLBuilder.textValue(for: subject) else {
        return .failure(failure)
      }
      return FantasticalActions.open(url: url(text), failure: failure, activates: activates())
    }
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { subject in
      FantasticalURLBuilder.textValue(for: subject) != nil
    }
    return action
  }

  private static func makeAppTextAction(
    id: String,
    title: String,
    symbolName: String,
    failure: String,
    activates: @escaping () -> Bool = { true },
    url: @escaping (String) -> URL?
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { _, target in
      guard let text = FantasticalURLBuilder.textValue(for: target) else {
        return .failure(failure)
      }
      return FantasticalActions.open(url: url(text), failure: failure, activates: activates())
    }
    action.targetRequirement = .required
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.application]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = FantasticalActions.isFantasticalApplication
    action.targetPredicate = { target in
      FantasticalURLBuilder.textValue(for: target) != nil
    }
    return action
  }
}

enum FantasticalActions {
  static func open(url: URL?, failure: String, activates: Bool = true) -> ActionResult {
    guard let url else {
      return .failure(failure)
    }
    guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
      return .failure("Fantastical is not installed")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    return .success
  }

  static func isFantasticalApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
      == FantasticalIdentifiers.bundleIdentifier
  }
}
