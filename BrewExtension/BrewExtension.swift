import Foundation
import TunaKit

@objc(BrewExtension)
public final class BrewExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Homebrew",
        author: "Tuna",
        description: "Search Homebrew formulae and casks.",
        iconName: "mug"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.80", minTunaKit: "1.17.0"),
      settings: [
        CatalogSettingDefinition(
          key: "CustomBrewPath",
          type: .string,
          label: "Custom brew executable path",
          defaultValue: "",
          description: "Optional absolute path to the brew executable. Leave blank to auto-detect."
        )
      ],
      catalogs: [
        CatalogDeclaration(
          id: "brew.packages",
          type: BrewCatalog.self,
          name: "Homebrew",
          enabledByDefault: false
        ),
        CatalogDeclaration(
          id: "brew.search",
          type: BrewSearchCatalog.self,
          name: "Homebrew",
          enabledByDefault: true
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "brew.actions",
          type: BrewActionCatalog.self,
          name: "Homebrew Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-meta"),
          displayName: "Homebrew",
          inheritsFrom: [
            TypeID("com.tuna.type.entity"), TypeID("com.tuna.type.search-catalog-entry"),
          ]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package"),
          displayName: "Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.entity")]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package-available"),
          displayName: "Available Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package-installed"),
          displayName: "Installed Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package-outdated"),
          displayName: "Outdated Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-meta"),
          actions: [
            ActionReference(catalogIdentifier: "brew.actions", actionID: "browse-installed"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "browse-outdated"),
            ActionReference(
              catalogIdentifier: "brew.actions", actionID: "install-from-text"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "install-cask"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "update"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "upgrade-all"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "cleanup"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-available"),
          actions: [
            ActionReference(catalogIdentifier: "brew.actions", actionID: "install"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-installed"),
          actions: [
            ActionReference(catalogIdentifier: "brew.actions", actionID: "uninstall"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-outdated"),
          actions: [
            ActionReference(catalogIdentifier: "brew.actions", actionID: "upgrade"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "uninstall"),
            ActionReference(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
      ]
    )
  }
}
