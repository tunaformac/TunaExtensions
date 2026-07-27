import AppKit
import Foundation
import TunaKit

public final class NotesActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.actions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }


  static func actions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let openInNotes = PredicateAwareAction(
      id: "open-in-notes", title: "Open in Notes", type: .action
    ) { subject, _ in
      guard let note = subject as? NoteItem else {
        return .failure("No note selected")
      }
      guard let url = NotesActions.urlToOpen(noteIdentifier: note.noteIdentifier) else {
        return .failure("Invalid note URL")
      }
      NSWorkspace.shared.open(url)
      return .success
    }
    openInNotes.systemSymbolName = "arrow.up.right.square"
    openInNotes.supportedSubjectTypes = [.note]
    openInNotes.subjectPredicate = { $0 is NoteItem }
    items.append(openInNotes)

    let createFromText = PredicateAwareAction(
      id: "create-note", title: "Create Note", type: .action
    ) { subject, _ in
      guard subject.typeID == .textSnippet else {
        return .failure("Select text first")
      }
      guard let body = subject.textValueFallback() else {
        return .failure("Missing note text")
      }
      Task.detached(priority: .utility) {
        await NotesActions.runCreateNote(from: body)
      }
      return .success
    }
    createFromText.systemSymbolName = "plus.circle"
    createFromText.supportedSubjectTypes = [.textSnippet]
    createFromText.subjectPredicate = { subject in
      guard let subject else { return false }
      return subject.typeID == .textSnippet && subject.textValueFallback() != nil
    }
    items.append(createFromText)

    let createFromApp = PredicateAwareAction(
      id: "create-note.from-app", title: "Create Note", type: .action
    ) { _, target in
      guard let body = target?.textValueFallback() else {
        return .failure("Missing note text")
      }
      Task.detached(priority: .utility) {
        await NotesActions.runCreateNote(from: body)
      }
      return .success
    }
    createFromApp.targetRequirement = .required
    createFromApp.systemSymbolName = "plus.circle"
    createFromApp.supportedSubjectTypes = [.application]
    createFromApp.allowedTargetTypes = [.textSnippet]
    createFromApp.subjectPredicate = NotesActions.isNotesApplication
    createFromApp.targetPredicate = { item in item?.textValueFallback() != nil }
    items.append(createFromApp)

    let toAction = PredicateAwareAction(id: "to", title: "To...", type: .action) {
      subject, target in
      guard NotesActions.isNewNoteEntry(subject) else {
        return .failure("Select New Note first")
      }
      guard let body = target?.textValueFallback() else {
        return .failure("Missing note text")
      }
      Task.detached(priority: .utility) {
        await NotesActions.runCreateNote(from: body)
      }
      return .success
    }
    toAction.targetRequirement = .required
    toAction.systemSymbolName = "plus.circle"
    toAction.supportedSubjectTypes = Set([TypeID.searchCatalogEntry])
    toAction.allowedTargetTypes = Set([TypeID.textSnippet])
    toAction.subjectPredicate = { subject in NotesActions.isNewNoteEntry(subject) }
    toAction.targetPredicate = { item in item?.textValueFallback() != nil }
    items.append(toAction)

    return items
  }
}

private enum NotesActions {
  static func urlToOpen(noteIdentifier: String) -> URL? {
    let trimmed = noteIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "notes"
    components.host = "showNote"
    components.queryItems = [URLQueryItem(name: "identifier", value: trimmed)]
    return components.url
  }

  static func isNewNoteEntry(_ subject: CatalogItem?) -> Bool {
    guard let subject else { return false }
    guard subject.typeID == .searchCatalogEntry else { return false }
    return subject.id == "notes.new"
  }

  static func isNotesApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.apple.Notes"
  }

  static func runCreateNote(from body: String) async {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      UserFeedback.beep()
      return
    }

    let title =
      trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
      ?? "New Note"

    let script = """
      on run argv
        set noteTitle to item 1 of argv
        set noteBody to item 2 of argv
        tell application "Notes"
          activate
          set theFolder to folder 1
          set theNote to make new note at theFolder with properties {name:noteTitle, body:noteBody}
          show theNote
        end tell
      end run
      """

    do {
      let result = try CLIProcessRunner.runSync(
        CLIProcessRequest(
          executablePath: "/usr/bin/osascript",
          arguments: ["-e", script, title, trimmed]
        ))
      if !result.succeeded {
        UserFeedback.beep()
      }
    } catch {
      UserFeedback.beep()
    }
  }
}
