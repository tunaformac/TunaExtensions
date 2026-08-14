import AppKit
import Foundation
import TunaKit

/// One catalog for every Things verb. The app-scoped ones used to live in a
/// second catalog to dodge the old app-action-enrichment gate; they scope
/// themselves through `ThingsActions.isThingsApplication` and never needed it
/// (ADR 0006).
public final class ThingsActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions() + Self.appActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }
}

extension ThingsActionsCatalog {
  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let showList = PredicateAwareAction(
      id: "show-in-things", title: "Show in Things"
    ) { subject, _ in
      guard let listItem = subject as? ThingsListItem else {
        return .failure("No Things list selected")
      }
      return ThingsActions.open(
        url: ThingsURLBuilder.showURL(listID: listItem.listID, query: listItem.query),
        failure: "Invalid Things list URL"
      )
    }
    showList.systemSymbolName = "checklist"
    showList.supportedSubjectTypes = [.thingsList]
    showList.subjectPredicate = { $0 is ThingsListItem }
    items.append(showList)

    let addToThings = PredicateAwareAction(
      id: "add-to-things", title: "Add to Things"
    ) { subject, _ in
      ThingsActions.open(
        url: ThingsURLBuilder.addURL(from: [subject]),
        failure: "Nothing to add",
        activates: ThingsSettings.activateWhenAdding
      )
    }
    addToThings.batchCallback = { subjects, _ in
      ThingsActions.open(
        url: ThingsURLBuilder.addURL(from: subjects),
        failure: "Nothing to add",
        activates: ThingsSettings.activateWhenAdding
      )
    }
    addToThings.systemSymbolName = "plus.circle"
    addToThings.supportedSubjectTypes = [.textSnippet]
    addToThings.subjectPredicate = { subject in
      ThingsURLBuilder.textTitle(for: subject) != nil
    }
    items.append(addToThings)

    let addQuickEntry = PredicateAwareAction(
      id: "add-to-things-quick-entry", title: "Add to Things (Quick Entry)"
    ) {
      subject, _ in
      ThingsActions.open(
        url: ThingsURLBuilder.addURL(from: [subject], showQuickEntry: true),
        failure: "Nothing to add",
        activates: true
      )
    }
    addQuickEntry.systemSymbolName = "square.and.pencil"
    addQuickEntry.supportedSubjectTypes = addToThings.supportedSubjectTypes
    addQuickEntry.subjectPredicate = addToThings.subjectPredicate
    items.append(addQuickEntry)

    let addToToday = PredicateAwareAction(
      id: "add-to-today-in-things", title: "Add to Today in Things"
    ) { subject, _ in
      ThingsActions.open(
        url: ThingsURLBuilder.addURL(from: [subject], when: "today"),
        failure: "Nothing to add",
        activates: ThingsSettings.activateWhenAdding
      )
    }
    addToToday.batchCallback = { subjects, _ in
      ThingsActions.open(
        url: ThingsURLBuilder.addURL(from: subjects, when: "today"),
        failure: "Nothing to add",
        activates: ThingsSettings.activateWhenAdding
      )
    }
    addToToday.systemSymbolName = "sun.max"
    addToToday.supportedSubjectTypes = addToThings.supportedSubjectTypes
    addToToday.subjectPredicate = addToThings.subjectPredicate
    items.append(addToToday)

    let search = PredicateAwareAction(id: "search-things", title: "Search Things") {
      subject, _ in
      guard let query = ThingsURLBuilder.query(from: subject) else {
        return .failure("Missing search query")
      }
      return ThingsActions.open(
        url: ThingsURLBuilder.searchURL(query: query),
        failure: "Invalid search query"
      )
    }
    search.systemSymbolName = "magnifyingglass"
    search.supportedSubjectTypes = [.textSnippet]
    search.subjectPredicate = { subject in
      ThingsURLBuilder.query(from: subject) != nil
    }
    items.append(search)

    return items
  }

  static func appActions() -> [CatalogAction] {
    [
      makeAppTextAction(
        id: "create-to-do",
        title: "Create To-Do",
        symbolName: "plus.circle",
        failure: "Missing to-do title"
      ) { title in
        ThingsURLBuilder.addURL(title: title, note: nil, when: nil)
      },
      makeAppTextAction(
        id: "create-today-to-do",
        title: "Create Today To-Do",
        symbolName: "sun.max",
        failure: "Missing to-do title"
      ) { title in
        ThingsURLBuilder.addURL(title: title, note: nil, when: "today")
      },
      makeAppTextAction(
        id: "create-quick-entry",
        title: "Create Quick Entry",
        symbolName: "square.and.pencil",
        failure: "Missing to-do title",
        activates: true
      ) { title in
        ThingsURLBuilder.addURL(title: title, note: nil, when: nil, showQuickEntry: true)
      },
      makeAppTextAction(
        id: "search",
        title: "Search",
        symbolName: "magnifyingglass",
        failure: "Missing search query"
      ) { query in
        ThingsURLBuilder.searchURL(query: query)
      },
    ]
  }

  private static func makeAppTextAction(
    id: String,
    title: String,
    symbolName: String,
    failure: String,
    activates: Bool? = nil,
    url: @escaping (String) -> URL?
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { _, target in
      guard let text = target?.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
      else {
        return .failure(failure)
      }
      return ThingsActions.open(
        url: url(text), failure: failure, activates: activates ?? ThingsSettings.activateWhenAdding)
    }
    action.targetRequirement = .required
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.application]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = ThingsActions.isThingsApplication
    action.targetPredicate = { target in
      guard let text = target?.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
      else { return false }
      return !text.isEmpty
    }
    return action
  }
}

enum ThingsURLBuilder {
  static func addURL(
    from subjects: [CatalogItem],
    when: String? = nil,
    showQuickEntry: Bool = false
  ) -> URL? {
    let titles = subjects.compactMap(textTitle)
    guard !titles.isEmpty else { return nil }

    if titles.count == 1 {
      return addURL(
        title: titles[0],
        note: nil,
        when: when,
        showQuickEntry: showQuickEntry
      )
    }

    guard !showQuickEntry else { return nil }
    return addURL(titles: titles, when: when)
  }

  static func addURL(
    title: String?,
    note: String?,
    when: String?,
    showQuickEntry: Bool = false
  ) -> URL? {
    guard let title, !title.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "things"
    components.host = ""
    components.path = "/add"

    var queryItems = [percentEncodedQueryItem(name: "title", value: title)]
    if let note, !note.isEmpty {
      queryItems.append(percentEncodedQueryItem(name: "notes", value: note))
    }
    if let when, !when.isEmpty {
      queryItems.append(percentEncodedQueryItem(name: "when", value: when))
    }
    if showQuickEntry {
      queryItems.append(URLQueryItem(name: "show-quick-entry", value: "true"))
    }
    components.percentEncodedQueryItems = queryItems

    return components.url
  }

  static func addURL(titles: [String], when: String? = nil) -> URL? {
    let trimmedTitles = titles.compactMap { normalize($0) }
    guard !trimmedTitles.isEmpty else { return nil }

    var components = URLComponents()
    components.scheme = "things"
    components.host = ""
    components.path = "/add"
    var queryItems = [
      percentEncodedQueryItem(name: "titles", value: trimmedTitles.joined(separator: "\n"))
    ]
    if let when, !when.isEmpty {
      queryItems.append(percentEncodedQueryItem(name: "when", value: when))
    }
    components.percentEncodedQueryItems = queryItems

    return components.url
  }

  static func showURL(listID: String?, query: String?) -> URL? {
    let listID = normalize(listID)
    let query = normalize(query)
    var components = URLComponents()
    components.scheme = "things"
    components.host = ""
    components.path = "/show"

    if let listID {
      components.percentEncodedQueryItems = [percentEncodedQueryItem(name: "id", value: listID)]
    } else if let query {
      components.percentEncodedQueryItems = [percentEncodedQueryItem(name: "query", value: query)]
    } else {
      return nil
    }

    return components.url
  }

  static func searchURL(query: String) -> URL? {
    guard let query = normalize(query) else { return nil }

    var components = URLComponents()
    components.scheme = "things"
    components.host = ""
    components.path = "/search"
    components.percentEncodedQueryItems = [percentEncodedQueryItem(name: "query", value: query)]

    return components.url
  }

  /// Percent-encodes a query value using only RFC 3986 unreserved characters, so literal "+"
  /// is escaped to "%2B" instead of being left ambiguous with encoded spaces (unlike
  /// `URLQueryItem`'s default `.urlQueryAllowed` encoding, which leaves "+" untouched).
  private static func percentEncodedQueryItem(name: String, value: String) -> URLQueryItem {
    URLQueryItem(
      name: name,
      value: value.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? value)
  }

  static func query(from subject: CatalogItem?) -> String? {
    textTitle(for: subject)
  }

  static func textTitle(for subject: CatalogItem?) -> String? {
    normalize(subject?.textInputValue())
  }

  private static func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension CharacterSet {
  fileprivate static let rfc3986Unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private enum ThingsActions {
  static func open(url: URL?, failure: String, activates: Bool = true) -> ActionResult {
    guard let url else {
      return .failure(failure)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    return .success
  }

  static func isThingsApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.culturedcode.ThingsMac"
  }
}

private enum ThingsSettings {
  static let showWhenAddingKey = "ShowThingsWhenAdding"
  static let showWhenAddingDefault = "true"
  static var activateWhenAdding: Bool {
    let store = CatalogSettingStore(catalogIdentifier: extensionIdentifier)
    let raw = store.stringValue(for: showWhenAddingKey, defaultValue: showWhenAddingDefault)
    return raw.lowercased() != "false"
  }

  private static let extensionIdentifier: String = {
    let bundle = Bundle(for: ThingsActionsCatalog.self)
    return bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaThings")
  }()
}
