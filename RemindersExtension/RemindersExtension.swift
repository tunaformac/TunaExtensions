import Foundation
import TunaKit

@objc(RemindersExtension)
public final class RemindersExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Reminders",
        author: "Tuna",
        description: "Search reminders and create them in specific lists.",
        iconName: "checklist"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      catalogs: [
        CatalogDeclaration(
          id: "reminders", type: RemindersCatalog.self, name: "Reminders",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "reminders.search", type: RemindersSearchCatalog.self, name: "Reminders",
          presentation: .browseRoot(contents: "reminders"), enabledByDefault: true),
        CatalogDeclaration(
          id: "reminders.lists", type: RemindersListsCatalog.self, name: "Reminder Lists",
          presentation: .source, enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "reminders.actions", type: RemindersActionsCatalog.self,
          name: "Reminders Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.reminder"), displayName: "Reminders",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.reminder-list"), displayName: "Reminder Lists",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.reminder"),
          actions: [
            ActionReference(
              catalogIdentifier: "reminders.actions", actionID: "mark-complete"),
            ActionReference(
              catalogIdentifier: "reminders.actions", actionID: "open-in-reminders"),
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
