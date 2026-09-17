import Foundation
import TunaKit

@objc(FantasticalExtension)
public final class FantasticalExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Fantastical",
        author: "miiraheart",
        description: "Add events and tasks to Fantastical, jump to its views.",
        iconName: "calendar"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: [
        CatalogSettingDefinition(
          key: FantasticalSettings.addImmediatelyKey,
          type: .bool,
          label: "Add without confirmation",
          defaultValue: "false",
          description:
            "When off, Fantastical shows how it parsed your text and Enter confirms. When on, items are added silently."
        ),
        CatalogSettingDefinition(
          key: FantasticalSettings.useMiniWindowKey,
          type: .bool,
          label: "Use the Mini Window",
          defaultValue: "true",
          description: "Open parse and search results in Fantastical's menu bar Mini Window instead of the main window."
        ),
        CatalogSettingDefinition(
          key: FantasticalSettings.fieldSeparatorKey,
          type: .string,
          label: "Field separator",
          defaultValue: FantasticalFields.defaultSeparator,
          description:
            "Separates the sentence from fields: title, start, end, due, allday, cal, url, notes. Example: Dentist tomorrow 15h -- notes: bring card -- cal: Perso"
        ),
        CatalogSettingDefinition(
          key: FantasticalSettings.calendarSetsKey,
          type: .string,
          label: "Calendar sets",
          defaultValue: "",
          description:
            "Comma-separated calendar set names, exactly as shown in Fantastical. Each becomes a destination you can jump to."
        ),
      ],
      catalogs: [
        CatalogDeclaration(
          id: FantasticalIdentifiers.agendaCatalog, type: FantasticalAgendaCatalog.self,
          name: "Fantastical", presentation: .liveSearch,
          description: "Search events and tasks as you type, or browse the next days.",
          enabledByDefault: true),
        CatalogDeclaration(
          id: FantasticalIdentifiers.catalog, type: FantasticalCatalog.self, name: "Fantastical Views",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: FantasticalIdentifiers.calendarsCatalog, type: FantasticalCalendarsCatalog.self,
          name: "Fantastical Calendars", presentation: .source,
          description: "Writable calendars, the targets of Add to Fantastical Calendar.",
          enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: FantasticalIdentifiers.actionCatalog, type: FantasticalActionsCatalog.self,
          name: "Fantastical Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID.fantasticalDestination, displayName: "Fantastical Views",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
        TypeRegistrationDefinition(
          typeID: TypeID.fantasticalItem, displayName: "Fantastical Items",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
        TypeRegistrationDefinition(
          typeID: TypeID.fantasticalCalendar, displayName: "Fantastical Calendars",
          inheritsFrom: [TypeID("com.tuna.type.entity")]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID.fantasticalDestination,
          actions: [
            ActionReference(
              catalogIdentifier: FantasticalIdentifiers.actionCatalog,
              actionID: FantasticalIdentifiers.showAction)
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID.fantasticalItem,
          actions: [
            ActionReference(
              catalogIdentifier: FantasticalIdentifiers.actionCatalog,
              actionID: FantasticalIdentifiers.showItemAction),
            ActionReference(
              catalogIdentifier: FantasticalIdentifiers.actionCatalog, actionID: "reschedule"),
          ]
        ),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: [FantasticalIdentifiers.bundleIdentifier],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: FantasticalIdentifiers.agendaCatalog),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: FantasticalIdentifiers.catalog),
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: [FantasticalIdentifiers.bundleIdentifier],
          catalogIdentifiers: [FantasticalIdentifiers.actionCatalog]
        )
      ]
    )
  }
}

enum FantasticalIdentifiers {
  static let bundleIdentifier = "com.flexibits.fantastical2.mac"
  static let catalog = "fantastical"
  static let agendaCatalog = "fantastical.agenda"
  static let calendarsCatalog = "fantastical.calendars"
  static let actionCatalog = "fantastical.actions"
  static let showAction = "show-in-fantastical"
  static let showItemAction = "show-item-in-fantastical"
}
