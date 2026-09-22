import AppKit
import Foundation
import TunaKit

public final class FantasticalActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions() + Self.agendaActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }
}

extension FantasticalActionsCatalog {
  static let textActionIDs = [
    "add-to-fantastical", "add-task-to-fantastical", "search-fantastical", "show-date-in-fantastical",
    FantasticalIdentifiers.addTypedAction,
  ]

  static let appActionIDs = [FantasticalIdentifiers.miniWindowAction]

  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let show = PredicateAwareAction(
      id: FantasticalIdentifiers.showAction, title: "Show in Fantastical"
    ) { subject, _ in
      if let view = subject as? FantasticalDestinationItem {
        return FantasticalActions.open(
          url: FantasticalURLBuilder.showURL(for: view.destination), failure: "Invalid Fantastical URL")
      }
      if let entity = subject as? FantasticalAgendaEntity {
        let url =
          entity.item.start.flatMap { FantasticalURLBuilder.dateURL($0) }
          ?? FantasticalURLBuilder.searchURL(query: entity.title, miniWindow: false)
        return FantasticalActions.open(url: url, failure: "Invalid Fantastical URL")
      }
      return .failure("Nothing to show")
    }
    show.systemSymbolName = "arrow.up.right.square"
    show.supportedSubjectTypes = [.fantasticalDestination, .fantasticalItem]
    show.subjectPredicate = { $0 is FantasticalDestinationItem || $0 is FantasticalAgendaEntity }
    items.append(show)

    let openMini = PredicateAwareAction(
      id: FantasticalIdentifiers.miniWindowAction, title: "Open Mini Window"
    ) { subject, _ in
      guard FantasticalActions.isFantasticalApplication(subject) else {
        return .failure("Select Fantastical first")
      }
      return FantasticalActions.open(
        url: FantasticalURLBuilder.showURL(for: .miniWindow), failure: "Invalid Fantastical URL")
    }
    openMini.systemSymbolName = "menubar.rectangle"
    openMini.supportedSubjectTypes = [.application]
    openMini.subjectPredicate = { FantasticalActions.isFantasticalApplication($0) }
    items.append(openMini)

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

    let addTyped = PredicateAwareAction(id: FantasticalIdentifiers.addTypedAction, title: "Add...") { subject, target in
      guard let entry = subject as? FantasticalNewItemEntry else {
        return .failure("Select New Event or New Task first")
      }
      if let calendar = entry.calendar {
        return FantasticalActions.add(subject: target, calendar: calendar)
      }
      return FantasticalActions.add(subject: target, task: entry.isTask)
    }
    addTyped.targetRequirement = .required
    addTyped.systemSymbolName = "plus.circle"
    addTyped.supportedSubjectTypes = [.searchCatalogEntry]
    addTyped.allowedTargetTypes = [.textSnippet]
    addTyped.subjectPredicate = { $0 is FantasticalNewItemEntry }
    addTyped.targetPredicate = { FantasticalURLBuilder.textValue(for: $0) != nil }
    items.append(addTyped)

    return items
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
}

enum FantasticalActions {
  static func add(subject: CatalogItem?, task: Bool) -> ActionResult {
    add(subject: subject) { fields in
      FantasticalURLBuilder.parseURL(
        fields: fields, task: task, addImmediately: FantasticalSettings.addImmediately,
        miniWindow: FantasticalSettings.useMiniWindow)
    }
  }

  static func add(subject: CatalogItem?, calendar: FantasticalCalendar) -> ActionResult {
    add(subject: subject) { fields in
      parseURL(
        fields: fields, calendar: calendar, addImmediately: FantasticalSettings.addImmediately,
        miniWindow: FantasticalSettings.useMiniWindow)
    }
  }

  /// The picked calendar replaces any `cal:` field; a task list turns the item into a task.
  static func parseURL(
    fields: FantasticalFields, calendar: FantasticalCalendar, addImmediately: Bool, miniWindow: Bool
  ) -> URL? {
    var fields = fields
    fields.calendarName = calendar.title
    let task = calendar.supportsTasks && (!calendar.supportsEvents || fields.due != nil)
    return FantasticalURLBuilder.parseURL(
      fields: fields, task: task, addImmediately: addImmediately, miniWindow: miniWindow)
  }

  private static func add(subject: CatalogItem?, url: (FantasticalFields) -> URL?) -> ActionResult {
    let fields: FantasticalFields
    do {
      fields = try self.fields(for: subject)
    } catch let error as FantasticalFields.ParseError {
      return .failure(error.message)
    } catch {
      return .failure("Nothing to add")
    }
    let addImmediately = FantasticalSettings.addImmediately
    let result = open(url: url(fields), failure: "Nothing to add", activates: !addImmediately)
    if case .success = result {
      FantasticalAgendaSupport.postDataDidChangeAfterCreate(previewShown: !addImmediately)
    }
    return result
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
