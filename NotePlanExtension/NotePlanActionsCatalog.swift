import AppKit
import Foundation
import TunaKit

public final class NotePlanActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] =
    Self.openActions() + Self.pluginActions() + Self.textActions() + Self.appActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }
}

extension NotePlanActionsCatalog {
  /// Verbs on a NotePlan note, folder, or calendar note.
  static func openActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let open = PredicateAwareAction(id: "open-in-noteplan", title: "Open in NotePlan") {
      subject, _ in
      guard let item = subject as? NotePlanOpenable else {
        return .failure("No NotePlan item selected")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.openURL(for: item.reference), failure: "Invalid NotePlan link")
    }
    open.systemSymbolName = "arrow.up.right.square"
    open.supportedSubjectTypes = [.notePlanNote, .notePlanFolder]
    open.subjectPredicate = { $0 is NotePlanOpenable }
    items.append(open)

    let openInNewWindow = PredicateAwareAction(
      id: "open-in-new-window", title: "Open in New NotePlan Window"
    ) { subject, _ in
      guard let item = subject as? NotePlanOpenable else {
        return .failure("No NotePlan note selected")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.openURL(for: item.reference, style: .newWindow),
        failure: "Invalid NotePlan link")
    }
    openInNewWindow.systemSymbolName = "macwindow.badge.plus"
    openInNewWindow.supportedSubjectTypes = [.notePlanNote]
    openInNewWindow.subjectPredicate = { $0 is NotePlanOpenable }
    items.append(openInNewWindow)

    let openInSplitView = PredicateAwareAction(
      id: "open-in-split-view", title: "Open in NotePlan Split View"
    ) { subject, _ in
      guard let item = subject as? NotePlanOpenable else {
        return .failure("No NotePlan note selected")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.openURL(for: item.reference, style: .splitView),
        failure: "Invalid NotePlan link")
    }
    openInSplitView.systemSymbolName = "rectangle.split.2x1"
    openInSplitView.supportedSubjectTypes = [.notePlanNote]
    openInSplitView.subjectPredicate = { $0 is NotePlanOpenable }
    items.append(openInSplitView)

    let appendText = PredicateAwareAction(id: "append-text", title: "Append Text...") {
      subject, target in
      guard let item = subject as? NotePlanOpenable else {
        return .failure("No NotePlan note selected")
      }
      guard let text = target?.textInputValue() else {
        return .failure("Missing text")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.addTextURL(text: text, to: item.reference),
        failure: "Missing text", activates: false)
    }
    appendText.targetRequirement = .required
    appendText.systemSymbolName = "text.append"
    appendText.supportedSubjectTypes = [.notePlanNote]
    appendText.allowedTargetTypes = [.textSnippet]
    appendText.subjectPredicate = { $0 is NotePlanOpenable }
    appendText.targetPredicate = NotePlanActions.hasText
    items.append(appendText)

    return items
  }

  /// Verbs on a NotePlan plugin command.
  static func pluginActions() -> [CatalogAction] {
    let run = PredicateAwareAction(id: "run-plugin-command", title: "Run in NotePlan") {
      subject, _ in
      guard let item = subject as? NotePlanPluginCommandItem else {
        return .failure("No NotePlan plugin command selected")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.runPluginURL(
          pluginID: item.record.pluginID, command: item.record.name),
        failure: "Invalid NotePlan plugin command")
    }
    run.systemSymbolName = "play.circle"
    run.supportedSubjectTypes = [.notePlanPluginCommand]
    run.subjectPredicate = { $0 is NotePlanPluginCommandItem }
    return [run]
  }

  /// Verbs on typed or selected text.
  static func textActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let addToToday = PredicateAwareAction(
      id: "add-to-today", title: "Add to Today in NotePlan"
    ) { subject, _ in
      NotePlanActions.open(
        url: NotePlanURLBuilder.addTextURL(
          text: subject.textInputValue() ?? "", to: .calendar(.today)),
        failure: "Nothing to add", activates: false)
    }
    addToToday.systemSymbolName = "sun.max"
    addToToday.supportedSubjectTypes = [.textSnippet]
    addToToday.subjectPredicate = NotePlanActions.hasText
    items.append(addToToday)

    let addTaskToToday = PredicateAwareAction(
      id: "add-task-to-today", title: "Add Task to Today in NotePlan"
    ) { subject, _ in
      NotePlanActions.open(
        url: NotePlanURLBuilder.addTextURL(
          text: NotePlanURLBuilder.taskLine(subject.textInputValue() ?? "") ?? "",
          to: .calendar(.today)),
        failure: "Nothing to add", activates: false)
    }
    addTaskToToday.systemSymbolName = "checkmark.circle"
    addTaskToToday.supportedSubjectTypes = [.textSnippet]
    addTaskToToday.subjectPredicate = NotePlanActions.hasText
    items.append(addTaskToToday)

    let appendToNote = PredicateAwareAction(
      id: "append-to-note", title: "Append to NotePlan Note..."
    ) { subject, target in
      guard let item = target as? NotePlanOpenable else {
        return .failure("No NotePlan note selected")
      }
      return NotePlanActions.open(
        url: NotePlanURLBuilder.addTextURL(
          text: subject.textInputValue() ?? "", to: item.reference),
        failure: "Nothing to add", activates: false)
    }
    appendToNote.targetRequirement = .required
    appendToNote.systemSymbolName = "text.append"
    appendToNote.supportedSubjectTypes = [.textSnippet]
    appendToNote.allowedTargetTypes = [.notePlanNote]
    appendToNote.subjectPredicate = NotePlanActions.hasText
    appendToNote.targetPredicate = { $0 is NotePlanOpenable }
    items.append(appendToNote)

    let createNote = PredicateAwareAction(
      id: "create-note", title: "Create NotePlan Note"
    ) { subject, _ in
      NotePlanActions.open(
        url: NotePlanURLBuilder.addNoteURL(text: subject.textInputValue() ?? ""),
        failure: "Missing note title")
    }
    createNote.systemSymbolName = "square.and.pencil"
    createNote.supportedSubjectTypes = [.textSnippet]
    createNote.subjectPredicate = NotePlanActions.hasText
    items.append(createNote)

    let search = PredicateAwareAction(id: "search-noteplan", title: "Search NotePlan") {
      subject, _ in
      NotePlanActions.open(
        url: NotePlanURLBuilder.searchURL(query: subject.textInputValue() ?? ""),
        failure: "Missing search query")
    }
    search.systemSymbolName = "magnifyingglass"
    search.supportedSubjectTypes = [.textSnippet]
    search.subjectPredicate = NotePlanActions.hasText
    items.append(search)

    return items
  }

  /// Verbs on the NotePlan app itself, with typed text as the target.
  static func appActions() -> [CatalogAction] {
    [
      makeAppTextAction(
        id: "search", title: "Search", symbolName: "magnifyingglass",
        failure: "Missing search query"
      ) { NotePlanURLBuilder.searchURL(query: $0) },
      makeAppTextAction(
        id: "create-note.from-app", title: "Create Note", symbolName: "square.and.pencil",
        failure: "Missing note title"
      ) { NotePlanURLBuilder.addNoteURL(text: $0) },
      makeAppTextAction(
        id: "add-to-today.from-app", title: "Add to Today", symbolName: "sun.max",
        failure: "Nothing to add", activates: false
      ) { NotePlanURLBuilder.addTextURL(text: $0, to: .calendar(.today)) },
      makeAppTextAction(
        id: "add-task-to-today.from-app", title: "Add Task to Today",
        symbolName: "checkmark.circle", failure: "Nothing to add", activates: false
      ) {
        NotePlanURLBuilder.addTextURL(
          text: NotePlanURLBuilder.taskLine($0) ?? "", to: .calendar(.today))
      },
    ]
  }

  private static func makeAppTextAction(
    id: String,
    title: String,
    symbolName: String,
    failure: String,
    activates: Bool = true,
    url: @escaping (String) -> URL?
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { _, target in
      guard let text = NotePlanURLBuilder.normalize(target?.textInputValue()) else {
        return .failure(failure)
      }
      return NotePlanActions.open(url: url(text), failure: failure, activates: activates)
    }
    action.targetRequirement = .required
    action.systemSymbolName = symbolName
    action.supportedSubjectTypes = [.application]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = NotePlanActions.isNotePlanApplication
    action.targetPredicate = NotePlanActions.hasText
    return action
  }
}

private enum NotePlanActions {
  static func open(url: URL?, failure: String, activates: Bool = true) -> ActionResult {
    guard let url else {
      return .failure(failure)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activates
    NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    return .success
  }

  static func hasText(_ item: CatalogItem?) -> Bool {
    NotePlanURLBuilder.normalize(item?.textInputValue()) != nil
  }

  static func isNotePlanApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return NotePlanProvider.isNotePlanBundleIdentifier(
      Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier)
  }
}
