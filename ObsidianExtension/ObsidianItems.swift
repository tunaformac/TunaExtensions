import AppKit
import Foundation
import TunaKit

private enum ObsidianTypeRegistrations {
  static let registered: Void = {
    TypeRegistry.shared.register(.obsidianNote, inheritsFrom: [.file])
    TypeRegistry.shared.register(.obsidianVault, inheritsFrom: [.directory])
  }()
}

final class ObsidianVaultItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  private enum LoadPhase {
    case idle
    case loading
    case loaded
  }

  private struct ContentsState {
    var notes: [ObsidianNoteItem] = []
    var generation = 0
    var phase = LoadPhase.idle
  }

  let vaultName: String
  private let vaultPath: String
  private let catalogIdentifier: String?
  private let contentsState = LockedValue(ContentsState())

  init(vaultName: String, path: String, catalogIdentifier: String? = nil) {
    _ = ObsidianTypeRegistrations.registered
    self.vaultName = vaultName
    self.vaultPath = path
    self.catalogIdentifier = catalogIdentifier
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

  func hierarchyChildren() -> [CatalogItem] {
    requestLoadIfNeeded()
    return children(relativeFolderPath: "")
  }

  private func requestLoadIfNeeded() {
    let generation = contentsState.withValue { state -> Int? in
      guard state.phase == .idle else { return nil }
      state.phase = .loading
      return state.generation
    }
    if let generation { loadContents(generation: generation) }
  }

  func invalidateContents() {
    contentsState.withValue { state in
      state.notes = []
      state.generation += 1
      state.phase = .idle
    }
  }

  private func loadContents(generation: Int) {
    let vault = ObsidianVaultLocator.Vault(
      name: vaultName,
      url: URL(fileURLWithPath: vaultPath, isDirectory: true)
    )
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      let notes = ObsidianVaultContents.notes(in: vault, fileManager: .default)
      let accepted = contentsState.withValue { state in
        guard state.generation == generation, state.phase == .loading else { return false }
        state.notes = notes
        state.phase = .loaded
        return true
      }
      guard accepted, let catalogIdentifier else { return }
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
    }
  }

  private func children(relativeFolderPath: String) -> [CatalogItem] {
    requestLoadIfNeeded()
    let snapshot = contentsState.readValue { ($0.phase, $0.notes) }
    guard snapshot.0 == .loaded else {
      return [
        CatalogLoadingItem(
          title: "Loading \(vaultName)",
          message: "Scanning notes in this Obsidian vault."
        )
      ]
    }

    let contents = ObsidianVaultContents.folderContents(
      notes: snapshot.1,
      relativeFolderPath: relativeFolderPath
    )
    let folders: [CatalogItem] = contents.folderNames
      .map { folderName in
        let childRelativePath = relativeFolderPath.isEmpty
          ? folderName
          : relativeFolderPath + "/" + folderName
        let childPath = URL(fileURLWithPath: vaultPath, isDirectory: true)
          .appendingPathComponent(childRelativePath, isDirectory: true).path
        return ObsidianFolderItem(title: folderName, path: childPath) { [weak self] in
          self?.children(relativeFolderPath: childRelativePath) ?? []
        }
      }
    let notes: [CatalogItem] = contents.notes
    let children = folders + notes
    if !children.isEmpty { return children }

    return [
      CatalogMessageItem(
        title: "Empty vault",
        message: "This Obsidian vault contains no Markdown notes.",
        symbolName: "doc.text",
        tintColor: .secondaryLabelColor
      )
    ]
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

final class ObsidianFolderItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  private let childrenProvider: @Sendable () -> [CatalogItem]

  init(title: String, path: String, children: [CatalogItem]) {
    self.childrenProvider = { children }
    super.init(id: path, title: title, path: path)
    typeID = .directory
  }

  init(title: String, path: String, childrenProvider: @escaping @Sendable () -> [CatalogItem]) {
    self.childrenProvider = childrenProvider
    super.init(id: path, title: title, path: path)
    typeID = .directory
  }

  override var detail: String? { path }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("folder", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] { childrenProvider() }
}

enum ObsidianVaultContents {
  nonisolated static func notes(
    in vault: ObsidianVaultLocator.Vault,
    fileManager: FileManager
  ) -> [ObsidianNoteItem] {
    guard fileManager.fileExists(atPath: vault.url.path) else { return [] }
    guard
      let enumerator = fileManager.enumerator(
        at: vault.url,
        includingPropertiesForKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles],
        errorHandler: nil)
    else { return [] }

    var items: [ObsidianNoteItem] = []

    for case let url as URL in enumerator {
      let resourceValues = try? url.resourceValues(forKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .contentModificationDateKey,
      ])
      if resourceValues?.isDirectory == true {
        if shouldSkipDirectory(url) {
          enumerator.skipDescendants()
        }
        continue
      }

      guard resourceValues?.isRegularFile == true else { continue }
      guard url.pathExtension.lowercased() == "md" else { continue }

      let title = url.deletingPathExtension().lastPathComponent
      let relativePath = url.deletingPathExtension().path.replacing(vault.url.path + "/", with: "")
      items.append(
        ObsidianNoteItem(
          title: title,
          vaultName: vault.name,
          relativePath: relativePath,
          path: url.path,
          modifiedAt: resourceValues?.contentModificationDate ?? .distantPast
        ))
    }

    return items
  }

  static func hierarchy(notes: [ObsidianNoteItem], vaultPath: String) -> [CatalogItem] {
    hierarchy(notes: notes, vaultPath: vaultPath, relativeFolderPath: "")
  }

  static func folderContents(
    notes: [ObsidianNoteItem],
    relativeFolderPath: String
  ) -> (folderNames: [String], notes: [ObsidianNoteItem]) {
    let prefix = relativeFolderPath.isEmpty ? "" : relativeFolderPath + "/"
    var folderNames = Set<String>()
    var directNotes: [ObsidianNoteItem] = []

    for note in notes where note.relativePath.hasPrefix(prefix) {
      let remainder = String(note.relativePath.dropFirst(prefix.count))
      let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
      if components.count == 1 {
        directNotes.append(note)
      } else if let folderName = components.first {
        folderNames.insert(String(folderName))
      }
    }

    return (
      folderNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      directNotes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    )
  }

  nonisolated private static func shouldSkipDirectory(_ url: URL) -> Bool {
    switch url.lastPathComponent {
    case ".obsidian", ".git", "node_modules":
      return true
    default:
      return false
    }
  }

  private static func hierarchy(
    notes: [ObsidianNoteItem],
    vaultPath: String,
    relativeFolderPath: String
  ) -> [CatalogItem] {
    let contents = folderContents(notes: notes, relativeFolderPath: relativeFolderPath)
    let folders: [CatalogItem] = contents.folderNames.map { folderName in
      let childRelativePath = relativeFolderPath.isEmpty
        ? folderName
        : relativeFolderPath + "/" + folderName
      let path = URL(fileURLWithPath: vaultPath, isDirectory: true)
        .appendingPathComponent(childRelativePath, isDirectory: true).path
      return ObsidianFolderItem(
        title: folderName,
        path: path,
        children: hierarchy(
          notes: notes,
          vaultPath: vaultPath,
          relativeFolderPath: childRelativePath
        )
      )
    }
    return folders + contents.notes
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
