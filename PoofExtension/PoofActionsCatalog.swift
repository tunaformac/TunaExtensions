import AppKit
import Foundation
import TunaKit

@MainActor
public final class PoofActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeActions() -> [CatalogAction] {
    let edit = PredicateAwareAction(id: "edit-snippet", title: "Edit Snippet") { subject, _ in
      guard let snippet = subject as? PoofSnippetItem else {
        return .failure("Choose a Poof snippet")
      }
      return NSWorkspace.shared.open(snippet.record.sourceURL)
        ? .success : .failure("Unable to open the snippet file")
    }
    edit.supportedSubjectTypes = [.poofSnippet]
    edit.systemSymbolName = "square.and.pencil"
    edit.executionPolicy = .dismiss

    let delete = PredicateAwareAction(id: "delete-snippet", title: "Delete Snippet") {
      subject, _ in
      guard let snippet = subject as? PoofSnippetItem else {
        return .failure("Choose a Poof snippet")
      }
      let record = snippet.record
      return .review(
        ActionReviewSession(
          presentation: ActionReviewPresentation(
            title: "Delete Poof Snippet?",
            message: "This removes \(record.trigger) from \(record.sourceURL.lastPathComponent).",
            sections: [
              ActionReviewSection(
                id: "snippet",
                title: "Snippet",
                rows: [
                  ActionReviewRow(
                    id: record.trigger,
                    title: record.details ?? record.trigger,
                    detail: record.replacementTemplate
                  )
                ]
              )
            ],
            confirmButtonTitle: "Delete",
            isDestructive: true
          )
        ) { response in
          guard case .confirm = response else { return .success }
          do {
            try PoofSnippetStore(directory: PoofConfig.directory()).delete(record)
            await MainActor.run {
              NotificationCenter.default.post(name: .poofSnippetsChanged, object: nil)
            }
            return .success
          } catch {
            return .failure(error.localizedDescription)
          }
        }
      )
    }
    delete.supportedSubjectTypes = [.poofSnippet]
    delete.systemSymbolName = "trash"
    delete.executionPolicy = .keepVisible

    let create = PredicateAwareAction(id: "create-snippet", title: "Create Snippet") {
      subject, _ in
      guard let replacement = subject.textInputValue() else {
        return .failure("Choose text for the snippet")
      }
      guard let trigger = PoofCreateSnippetPrompt.requestTrigger() else { return .success }
      do {
        let record = try PoofSnippetStore(directory: PoofConfig.directory())
          .create(trigger: trigger, replacement: replacement)
        NotificationCenter.default.post(name: .poofSnippetsChanged, object: nil)
        return .subjects([PoofSnippetItem(record: record)])
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    create.supportedSubjectTypes = [.textSnippet]
    create.systemSymbolName = "plus.square"
    create.executionPolicy = .keepVisible

    let openLibrary = PredicateAwareAction(id: "open-library", title: "Open Snippets Folder") {
      subject, _ in
      guard let library = subject as? PoofLibraryItem else {
        return .failure("Choose the Poof Snippets library")
      }
      do {
        try FileManager.default.createDirectory(
          at: library.directoryURL, withIntermediateDirectories: true)
        return NSWorkspace.shared.open(library.directoryURL)
          ? .success : .failure("Unable to open the Poof snippets folder")
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    openLibrary.supportedSubjectTypes = [.poofLibrary]
    openLibrary.systemSymbolName = "folder"
    openLibrary.executionPolicy = .dismiss

    return [edit, delete, create, openLibrary]
  }
}

@MainActor
private enum PoofCreateSnippetPrompt {
  static func requestTrigger() -> String? {
    let field = NSTextField(string: ":")
    field.placeholderString = ":signature"
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

    let alert = NSAlert()
    alert.messageText = "Create Poof Snippet"
    alert.informativeText = "Enter the trigger Poof should expand."
    alert.alertStyle = .informational
    alert.accessoryView = field
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field

    while alert.runModal() == .alertFirstButtonReturn {
      let trigger = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trigger.isEmpty, trigger != ":" { return trigger }
      alert.informativeText = "Enter a trigger, such as :signature."
      NSSound.beep()
    }
    return nil
  }
}
