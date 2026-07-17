import AppKit
import Foundation
import TunaKit

final class NoteItem: CatalogItem, TextValueProviding, TimestampedCatalogItem, @unchecked Sendable {
  let noteIdentifier: String
  let folderName: String
  let snippet: String
  let modifiedAt: Date

  var capturedAtDate: Date { modifiedAt }

  var textValue: String {
    if !snippet.isEmpty { return snippet }
    return title
  }

  override var searchText: String {
    var keys = [title]
    if !folderName.isEmpty { keys.append(folderName) }
    if !snippet.isEmpty { keys.append(snippet) }
    return keys.joined(separator: " ")
  }

  override var detail: String? {
    var parts: [String] = []
    if !folderName.isEmpty {
      parts.append(folderName)
    }

    let relative = modifiedAt.formatted(.relative(presentation: .named))
    parts.append(relative)

    let normalizedSnippet = snippet.replacing("\n", with: " ").trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !normalizedSnippet.isEmpty {
      let prefix = String(normalizedSnippet.prefix(140))
      parts.append(prefix + (normalizedSnippet.count > 140 ? "…" : ""))
    }

    if parts.isEmpty { return nil }
    return parts.joined(separator: " • ")
  }

  init(title: String, identifier: String, folderName: String, snippet: String, modifiedAt: Date) {
    noteIdentifier = identifier
    self.folderName = folderName
    self.snippet = snippet
    self.modifiedAt = modifiedAt
    super.init(id: identifier, title: title, type: .entity)
    typeID = .note
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("note.text", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("note.text", tintColor: .secondaryLabelColor)
  }
}

final class NotesNewNoteItem: CatalogEntity, @unchecked Sendable {
  init() {
    super.init(id: "notes.new", title: "New Note", path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    "Create a note from typed text"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("plus.circle")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("plus.circle")
  }
}

extension NotesNewNoteItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    guard let catalogIdentifier else { return false }
    guard catalogIdentifier == "notes.actions" else { return false }
    return action.id == "to"
  }
}

extension TypeID {
  static let note = TypeID("com.tuna.type.note")
}
