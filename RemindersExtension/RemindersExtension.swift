import Foundation
import TunaKit

@objc(RemindersExtension)
public final class RemindersExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Reminders",
        author: "Tuna",
        description: "Search reminders and manage tasks.",
        iconName: "checklist"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.65", minTunaKit: "1.11.0"),
      catalogs: [
        CatalogDeclaration(
          id: "reminders", type: RemindersCatalog.self, name: "Reminders", enabledByDefault: true),
        CatalogDeclaration(
          id: "reminders.search", type: RemindersSearchCatalog.self, name: "Reminders",
          enabledByDefault: true),
        CatalogDeclaration(
          id: "reminders.actions", type: RemindersActionsCatalog.self, name: "Reminders Actions",
          enabledByDefault: true),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.reminder"), displayName: "Reminders",
          inheritsFrom: [TypeID("com.tuna.type.entity")])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.reminder"),
          actions: [
            DefaultActionIdentifier(
              catalogIdentifier: "reminders.search", actionID: "mark-complete"),
            DefaultActionIdentifier(
              catalogIdentifier: "reminders.search", actionID: "open-in-reminders"),
          ]
        )
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.reminders"],
          entries: [AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "reminders")]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: ["com.apple.reminders"],
          catalogIdentifiers: ["reminders.actions"]
        )
      ]
    )
  }
}
