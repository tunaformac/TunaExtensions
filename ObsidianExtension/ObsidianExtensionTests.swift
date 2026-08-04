import TunaKit
import XCTest

@testable import TunaObsidian

@MainActor
final class ObsidianExtensionTests: XCTestCase {
  func testParseVaultsFromObsidianConfig() {
    let json = """
      {
        "vaults": {
          "abc": { "path": "/Users/example/Documents/Vault B" },
          "def": { "path": "/Users/example/Documents/Vault A" }
        }
      }
      """

    let vaults = ObsidianVaultLocator.parseVaults(from: Data(json.utf8))
    XCTAssertEqual(vaults.map(\.name), ["Vault A", "Vault B"])
  }

  func testVaultURL() throws {
    let url = try XCTUnwrap(ObsidianActions.vaultURL(vaultName: "My Vault"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "obsidian")
    XCTAssertEqual(components.host, "open")

    let items = components.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "My Vault")
  }

  func testNoteURL() throws {
    let url = try XCTUnwrap(
      ObsidianActions.noteURL(vaultName: "My Vault", relativePath: "Folder/Note")
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "obsidian")
    XCTAssertEqual(components.host, "open")

    let items = components.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "My Vault")
    XCTAssertEqual(items.first(where: { $0.name == "file" })?.value, "Folder/Note")
  }

  func testNewNoteURL() throws {
    let url = try XCTUnwrap(
      ObsidianActions.newNoteURL(vaultName: "My Vault", name: "My Note", content: "Hello")
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "obsidian")
    XCTAssertEqual(components.host, "new")

    let items = components.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "My Vault")
    XCTAssertEqual(items.first(where: { $0.name == "name" })?.value, "My Note")
    XCTAssertEqual(items.first(where: { $0.name == "content" })?.value, "Hello")
  }

  func testDailyNoteURL() throws {
    let url = try XCTUnwrap(ObsidianActions.dailyNoteURL(vaultName: "My Vault"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "obsidian")
    XCTAssertEqual(components.host, "adv-uri")

    let items = components.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "daily" })?.value, "true")
    XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "My Vault")
  }

  func testSearchVaultURL() throws {
    let url = try XCTUnwrap(ObsidianActions.searchURL(vaultName: "My Vault", query: "hello"))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "obsidian")
    XCTAssertEqual(components.host, "search")

    let items = components.queryItems ?? []
    XCTAssertEqual(items.first(where: { $0.name == "vault" })?.value, "My Vault")
    XCTAssertEqual(items.first(where: { $0.name == "query" })?.value, "hello")
  }

  func testSanitizeNoteNameRemovesForbiddenCharacters() {
    let sanitized = ObsidianNoteNameSanitizer.sanitize("2025/12/28 01:10 \\ test")
    XCTAssertFalse(sanitized.contains("/"))
    XCTAssertFalse(sanitized.contains(":"))
    XCTAssertFalse(sanitized.contains("\\"))
  }

  func testObsidianNoteTypeInheritsFile() {
    let item = ObsidianNoteItem(
      title: "Note",
      vaultName: "Vault",
      relativePath: "Folder/Note",
      path: "/tmp/Note.md",
      modifiedAt: Date(timeIntervalSince1970: 123)
    )

    XCTAssertEqual(item.typeID, .obsidianNote)
    XCTAssertTrue(TypeRegistry.shared.inherits(item.typeID, from: .file))
    XCTAssertEqual(item.capturedAtDate, Date(timeIntervalSince1970: 123))
  }

  func testVaultHierarchyGroupsFoldersBeforeRootNotes() throws {
    let rootNote = ObsidianNoteItem(
      title: "Root",
      vaultName: "Vault",
      relativePath: "Root",
      path: "/tmp/Vault/Root.md",
      modifiedAt: .now
    )
    let nestedNote = ObsidianNoteItem(
      title: "Nested",
      vaultName: "Vault",
      relativePath: "Projects/Nested",
      path: "/tmp/Vault/Projects/Nested.md",
      modifiedAt: .now
    )

    let items = ObsidianVaultContents.hierarchy(
      notes: [rootNote, nestedNote],
      vaultPath: "/tmp/Vault"
    )

    let folder = try XCTUnwrap(items.first as? ObsidianFolderItem)
    XCTAssertEqual(folder.title, "Projects")
    XCTAssertEqual(folder.hierarchyChildren().map(\.title), ["Nested"])
    XCTAssertEqual(items.last?.title, "Root")
  }

  func testNotesCatalogDefaultsToMostRecentSort() {
    let catalog = ObsidianNotesCatalog(
      definition: CatalogDefinition(
        identifier: "obsidian.notes",
        name: "Notes",
        enabledByDefault: true,
        settings: []
      ))

    XCTAssertEqual(
      catalog.sortOptions.map(\.id),
      [
        CatalogSortOption.capturedAtDescending.id,
        CatalogSortOption.capturedAtAscending.id,
        CatalogSortOption.nameAscending.id,
        CatalogSortOption.nameDescending.id,
      ])
    XCTAssertEqual(catalog.defaultSortOptionID, CatalogSortOption.capturedAtDescending.id)
  }

  func testObsidianActionsExposeOpenInsteadOfOpenInObsidian() {
    let keys = ObsidianActionsCatalog.actions().map(\.title)

    XCTAssertTrue(keys.contains("Open"))
    XCTAssertFalse(keys.contains("Open in Obsidian"))
  }

  @MainActor
  func testDeclarationRegistersObsidianActionsCatalogAsDefaultActionSource() throws {
    let ext = try ObsidianExtension(bundle: Bundle(for: ObsidianExtension.self))
    let declaration = try XCTUnwrap(ext.declaration)

    XCTAssertTrue(
      declaration.actionCatalogs.contains {
        $0.id == "obsidian.actions" && $0.type == ObsidianActionsCatalog.self
      })
    XCTAssertFalse(declaration.catalogs.contains { $0.id == "obsidian.actions" })

    let noteRanking = try XCTUnwrap(
      declaration.defaultActionRankings.first {
        $0.typeID == TypeID("com.tuna.type.obsidian-note")
      })
    XCTAssertEqual(noteRanking.actions.first?.catalogIdentifier, "obsidian.actions")

    let catalog = ObsidianActionsCatalog(
      definition: ActionCatalogDefinition(
        identifier: ObsidianCatalogIdentifiers.actions,
        name: "Obsidian Actions"))
    let actionIDs = Set(catalog.actions.map(\.id))
    for ranking in declaration.defaultActionRankings {
      for reference in ranking.actions {
        XCTAssertTrue(
          actionIDs.contains(reference.actionID),
          "Missing declared default action \(reference.catalogIdentifier).\(reference.actionID)")
      }
    }
  }

  func testNoteFilteringKeepsObsidianOpenButHidesGenericOpen() throws {
    let item = ObsidianNoteItem(
      title: "Note",
      vaultName: "Vault",
      relativePath: "Folder/Note",
      path: "/tmp/Note.md",
      modifiedAt: .now
    )

    let obsidianOpen = try XCTUnwrap(
      ObsidianActionsCatalog.actions().first(where: { $0.title == "Open" })
    )

    let genericOpen = PredicateAwareAction(id: "open", title: "Open") { _, _ in
      .success
    }
    genericOpen.supportedSubjectTypes = [.file]

    XCTAssertTrue(item.allowsAction(obsidianOpen, catalogIdentifier: nil))
    XCTAssertFalse(item.allowsAction(genericOpen, catalogIdentifier: nil))
  }

  func testVaultFilteringAllowsObsidianActionsCatalog() throws {
    let vault = ObsidianVaultItem(vaultName: "Vault", path: "/tmp/Vault")
    let openVault = try XCTUnwrap(
      ObsidianActionsCatalog.actions().first(where: { $0.title == "Open Vault in Obsidian" })
    )

    XCTAssertTrue(
      vault.allowsAction(openVault, catalogIdentifier: ObsidianCatalogIdentifiers.actions))
  }
}
