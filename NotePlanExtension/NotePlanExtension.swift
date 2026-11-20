import Foundation
import TunaKit

@objc(NotePlanExtension)
public final class NotePlanExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "NotePlan",
        author: "NotePlan",
        description: "Open NotePlan notes, folders, and calendar notes, and capture text.",
        iconName: "calendar.day.timeline.left"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      catalogs: [
        CatalogDeclaration(
          id: "noteplan", type: NotePlanCatalog.self, name: "NotePlan Notes",
          presentation: .source, enabledByDefault: true, initialGlobalScope: .all),
        CatalogDeclaration(
          id: "noteplan.destinations", type: NotePlanDestinationsCatalog.self,
          name: "NotePlan Calendar Notes", presentation: .source, enabledByDefault: true,
          initialGlobalScope: .all),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "noteplan.actions", type: NotePlanActionsCatalog.self, name: "NotePlan Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .notePlanNote, displayName: "NotePlan Notes",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
        TypeRegistrationDefinition(
          typeID: .notePlanFolder, displayName: "NotePlan Folders",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .notePlanNote,
          actions: [
            ActionReference(catalogIdentifier: "noteplan.actions", actionID: "open-in-noteplan")
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .notePlanFolder,
          actions: [
            ActionReference(catalogIdentifier: "noteplan.actions", actionID: "open-in-noteplan")
          ]
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: NotePlanProvider.bundleIdentifiers,
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "noteplan.destinations"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "noteplan"),
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: NotePlanProvider.bundleIdentifiers,
          catalogIdentifiers: ["noteplan.actions"]
        )
      ]
    )
  }
}
