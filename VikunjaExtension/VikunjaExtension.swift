import Foundation
import TunaKit

@objc(VikunjaExtension)
public final class VikunjaExtension: Extension {
  nonisolated static let tasksCatalogIdentifier = "vikunja"
  nonisolated static let projectsCatalogIdentifier = "vikunja.projects"
  nonisolated static let actionsCatalogIdentifier = "vikunja.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Vikunja",
        author: "Crosby Hayton",
        description: "Search, browse, add, and complete tasks in a self-hosted Vikunja.",
        iconName: "checkmark.circle"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: [
        CatalogSettingDefinition(
          key: VikunjaSettings.defaultProjectKey,
          type: .string,
          label: "Default project",
          defaultValue: VikunjaSettings.defaultProjectDefault,
          description:
            "Project title (or numeric id) that receives tasks added without choosing a project."
        )
      ],
      catalogs: [
        CatalogDeclaration(
          id: Self.tasksCatalogIdentifier,
          type: VikunjaTasksCatalog.self,
          name: "Vikunja",
          presentation: .liveSearch,
          description: "Search open tasks as you type, or browse them grouped by due date.",
          enabledByDefault: true
        ),
        CatalogDeclaration(
          id: Self.projectsCatalogIdentifier,
          type: VikunjaProjectsCatalog.self,
          name: "Projects",
          presentation: .source,
          description: "Vikunja projects; browse into one to see its open tasks.",
          enabledByDefault: true
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier,
          type: VikunjaActionsCatalog.self,
          name: "Vikunja Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .vikunjaTask,
          displayName: "Vikunja Tasks",
          inheritsFrom: [.entity]
        ),
        TypeRegistrationDefinition(
          typeID: .vikunjaProject,
          displayName: "Vikunja Projects",
          inheritsFrom: [.entity]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .vikunjaTask,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: VikunjaActionsCatalog.openTaskActionID),
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: VikunjaActionsCatalog.markDoneActionID),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .vikunjaProject,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: VikunjaActionsCatalog.openProjectActionID)
          ]
        ),
      ]
    )
  }

  public override var connectionDefinitions: [ExtensionConnectionDefinition] {
    [VikunjaCatalogSupport.connectionDefinition]
  }
}

enum VikunjaSettings {
  static let defaultProjectKey = "DefaultProject"
  static let defaultProjectDefault = "Inbox"

  static var defaultProject: String {
    let store = CatalogSettingStore(catalogIdentifier: extensionIdentifier)
    let raw = store.stringValue(for: defaultProjectKey, defaultValue: defaultProjectDefault)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultProjectDefault : trimmed
  }

  static let extensionIdentifier: String = {
    let bundle = Bundle(for: VikunjaExtension.self)
    return bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaVikunja")
  }()
}

extension TypeID {
  static let vikunjaTask = TypeID("com.crosbyh.tuna.type.vikunja-task")
  static let vikunjaProject = TypeID("com.crosbyh.tuna.type.vikunja-project")
}
