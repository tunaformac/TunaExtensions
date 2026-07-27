import AppKit
import Foundation
import TunaKit

private enum ObsidianTypeRegistrations {
  static let registered: Void = {
    TypeRegistry.shared.register(.obsidianNote, inheritsFrom: [.file])
    TypeRegistry.shared.register(.obsidianVault, inheritsFrom: [.directory])
  }()
}

final class ObsidianVaultItem: CatalogEntity, @unchecked Sendable {
  let vaultName: String

  init(vaultName: String, path: String) {
    _ = ObsidianTypeRegistrations.registered
    self.vaultName = vaultName
    super.init(id: path, title: vaultName, path: path)
    typeID = .obsidianVault
  }

  override var detail: String? {
    path
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("folder", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension ObsidianVaultItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    guard let catalogIdentifier else { return false }
    guard catalogIdentifier == ObsidianCatalogIdentifiers.actions else { return false }

    switch action.id {
    case "open-vault-in-obsidian", "new-note", "new-note.from-app", "search-vault":
      return true
    default:
      return false
    }
  }
}

final class ObsidianNoteItem: CatalogEntity, TimestampedCatalogItem, @unchecked Sendable {
  let vaultName: String
  let relativePath: String
  let modifiedAt: Date

  var capturedAtDate: Date { modifiedAt }

  init(title: String, vaultName: String, relativePath: String, path: String, modifiedAt: Date) {
    _ = ObsidianTypeRegistrations.registered
    self.vaultName = vaultName
    self.relativePath = relativePath
    self.modifiedAt = modifiedAt
    super.init(id: path, title: title, path: path)
    typeID = .obsidianNote
  }

  override var searchText: String {
    [title, relativePath, vaultName].joined(separator: " ")
  }

  override var detail: String? {
    if relativePath.isEmpty { return vaultName }
    return "\(vaultName) • \(relativePath)"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    CatalogItemPreview.systemSymbol("doc.text", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension ObsidianNoteItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    // Obsidian's own Open action plus CommonActionsCatalog's generic Open action.
    let openActionIDs = [ObsidianActionHierarchyIdentifiers.openNote, "open"]
    guard openActionIDs.contains(action.id) else { return true }
    return action.supportsSubject(type: .obsidianNote) && !action.supportsSubject(type: .file)
  }
}

extension TypeID {
  static let obsidianNote = TypeID("com.tuna.type.obsidian-note")
  static let obsidianVault = TypeID("com.tuna.type.obsidian-vault")
}

final class ObsidianDailyNoteItem: CatalogEntity, Runnable, @unchecked Sendable {
  init() {
    super.init(id: "Open Daily Note", title: "Open Daily Note", path: nil)
    typeID = .command
  }

  override var detail: String? {
    "Opens your daily note in Obsidian (uses last used vault)"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("calendar", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func run() -> ActionResult {
    ObsidianCommandRunner.openDailyNote()
  }
}
