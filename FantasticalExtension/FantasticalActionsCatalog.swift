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
      makeAddAction(
        id: "add-to-fantastical", title: "Add to Fantastical", symbolName: "plus.circle",
        task: false))
    items.append(
      makeAddAction(
        id: "add-task-to-fantastical", title: "Add Task to Fantastical",
        symbolName: "checkmark.circle", task: true))

    items.append(
      makeQueryAction(
        id: "search-fantastical", title: "Search Fantastical", symbolName: "magnifyingglass",
        failure: "Missing search query"
      ) { text in
        FantasticalURLBuilder.searchURL(query: text, miniWindow: FantasticalSettings.useMiniWindow)
      })

    let showDate = makeQueryAction(
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
      makeAppAction(id: "new-event", title: "New Event", symbolName: "plus.circle") { target in
        FantasticalActions.add(subject: target, task: false)
      },
      makeAppAction(id: "new-task", title: "New Task", symbolName: "checkmark.circle") { target in
        FantasticalActions.add(subject: target, task: true)
      },
      makeAppAction(id: "search", title: "Search", symbolName: "magnifyingglass") { target in
        guard let text = FantasticalURLBuilder.textValue(for: target) else {
          return .failure("Missing search query")
        }
        return FantasticalActions.open(
          url: FantasticalURLBuilder.searchURL(
            query: text, miniWindow: FantasticalSettings.useMiniWindow),
          failure: "Missing search query")
      },
    ]
  }

  /// Typed text with inline fields, or a link item, becomes a Fantastical event or task.
  private static func makeAddAction(
    id: String, title: String, symbolName: String, task: Bool
  ) -> PredicateAwareAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      FantasticalActions.add(subject: subject, task: task)
    }
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.textSnippet, .url]
    action.subjectPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    return action
  }

  private static func makeQueryAction(
    id: String, title: String, symbolName: String, failure: String,
    url: @escaping (String) -> URL?
  ) -> PredicateAwareAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard let text = FantasticalURLBuilder.textValue(for: subject) else {
        return .failure(failure)
      }
      return FantasticalActions.open(url: url(text), failure: failure)
    }
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    return action
  }

  /// Subject is Fantastical.app, the typed text arrives as the target.
  private static func makeAppAction(
    id: String, title: String, symbolName: String,
    perform: @escaping (CatalogItem?) -> ActionResult
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { _, target in perform(target) }
    action.targetRequirement = .required
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.application]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = FantasticalActions.isFantasticalApplication
    action.targetPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    return action
  }
}

enum FantasticalActions {
  static func add(subject: CatalogItem?, task: Bool) -> ActionResult {
    let fields: FantasticalFields
    do {
      fields = try self.fields(for: subject)
    } catch let error as FantasticalFields.ParseError {
      return .failure(error.message)
    } catch {
      return .failure("Nothing to add")
    }
    let addImmediately = FantasticalSettings.addImmediately
    return open(
      url: FantasticalURLBuilder.parseURL(
        fields: fields, task: task, addImmediately: addImmediately,
        miniWindow: FantasticalSettings.useMiniWindow),
      failure: "Nothing to add",
      activates: !addImmediately)
  }

  static func fields(for item: CatalogItem?) throws -> FantasticalFields {
    guard let item, let text = FantasticalURLBuilder.textValue(for: item) else {
      throw FantasticalFields.ParseError.empty
    }
    if isLink(item) {
      var fields = FantasticalFields()
      fields.url = text
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      fields.sentence = title.isEmpty ? text : title
      return fields
    }
    return try FantasticalFields.parse(text, separator: FantasticalSettings.fieldSeparator).get()
  }

  static func isLink(_ item: CatalogItem) -> Bool {
    item is URLItem || TypeRegistry.shared.inherits(item.typeID, from: .url)
  }

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
