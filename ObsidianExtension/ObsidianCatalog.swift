import AppKit
import Foundation
import TunaKit

public final class ObsidianNotesCatalog: ObsidianCatalogBase, CatalogSortingProviding {
  public let sortOptions: [CatalogSortOption] = [
    .capturedAtDescending,
    .capturedAtAscending,
    .nameAscending,
    .nameDescending,
  ]

  public var defaultSortOptionID: String {
    CatalogSortOption.capturedAtDescending.id
  }

  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .all)
  }
}

public final class ObsidianSearchCatalog: ObsidianCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .search)
  }
}

public final class ObsidianVaultsCatalog: NSObject, Catalog, RetainedCatalogStateReleasing {
  public let identifier: String
  public let name: String

  private let vaultsStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }
    return vaultsStore.readValue { $0 }
  }

  public required init(
    definition: CatalogDefinition
  ) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }

  public func releaseRetainedState() {
    vaultsStore.value = []
    messageStore.value = nil
  }

  public func scan() async {
    if RuntimeEnvironment.isRunningTests {
      messageStore.value = nil
      vaultsStore.value = []
      reportScanFinished()
      return
    }

    let result = await Task.detached(priority: .utility) {
      ObsidianVaultLocator.locateVaults()
    }.value

    switch result {
    case .success(let vaults):
      messageStore.value = nil
      vaultsStore.value = vaults.map { vault in
        ObsidianVaultItem(vaultName: vault.name, path: vault.url.path)
      }
    case .failure(let error):
      vaultsStore.value = []
      messageStore.value = [
        CatalogMessageItem(
          title: "Obsidian Vaults Unavailable",
          message: ObsidianCatalogBase.userFacingErrorMessage(for: error),
          symbolName: "book.closed",
          tintColor: .systemOrange
        )
      ]
    }

    reportScanFinished()
  }
}

@MainActor
public class ObsidianCatalogBase: NSObject, Catalog, RetainedCatalogStateReleasing {
  enum Mode {
    case all
    case search
  }

  public let identifier: String
  public let name: String
  private let mode: Mode

  private let notesStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let dailyNoteItem = ObsidianDailyNoteItem()

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) {
      return message
    }

    switch mode {
    case .all:
      return notesStore.readValue { $0 }
    case .search:
      return [dailyNoteItem] + ObsidianActionsCatalog.actions()
    }
  }

  fileprivate init(
    definition: CatalogDefinition,
    mode: Mode
  ) {
    self.identifier = definition.identifier
    self.name = definition.name
    self.mode = mode
    super.init()
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete Obsidian catalog type instead.")
  }

  public func releaseRetainedState() {
    notesStore.value = []
    messageStore.value = nil
  }

  public func scan() async {
    if RuntimeEnvironment.isRunningTests {
      messageStore.value = nil
      notesStore.value = []
      reportScanFinished()
      return
    }

    let result = await Task.detached(priority: .utility) {
      ObsidianCatalogBase.scanNotes()
    }.value

    switch result {
    case .success(let notes):
      messageStore.value = nil
      notesStore.value = notes
    case .failure(let error):
      notesStore.value = []
      messageStore.value = [
        CatalogMessageItem(
          title: "Obsidian Notes Unavailable",
          message: Self.userFacingErrorMessage(for: error),
          symbolName: "book.closed",
          tintColor: .systemOrange
        )
      ]
    }

    reportScanFinished()
  }

  fileprivate static func userFacingErrorMessage(for error: ObsidianVaultLocator.LocatorError)
    -> String
  {
    switch error {
    case .obsidianConfigMissing:
      return "Open Obsidian once to create its config, or ensure your vaults are registered."
    case .invalidConfigData:
      return "Could not read your Obsidian vault list. Try opening Obsidian, then rescan."
    case .noVaultsDetected:
      return "No vaults were detected in Obsidian’s config."
    }
  }

  nonisolated private static func scanNotes() -> Result<
    [CatalogItem], ObsidianVaultLocator.LocatorError
  > {
    let fileManager = FileManager.default
    let vaultsResult = ObsidianVaultLocator.locateVaults(fileManager: fileManager)
    let vaults: [ObsidianVaultLocator.Vault]
    switch vaultsResult {
    case .success(let value):
      vaults = value
    case .failure(let error):
      return .failure(error)
    }

    var results: [ObsidianNoteItem] = []

    for vault in vaults {
      results.append(contentsOf: notes(in: vault, fileManager: fileManager))
    }

    results.sort { lhs, rhs in
      if lhs.modifiedAt != rhs.modifiedAt {
        return lhs.modifiedAt > rhs.modifiedAt
      }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    return .success(results)
  }

  nonisolated private static func notes(
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

  nonisolated private static func shouldSkipDirectory(_ url: URL) -> Bool {
    switch url.lastPathComponent {
    case ".obsidian", ".git", "node_modules":
      return true
    default:
      return false
    }
  }
}
