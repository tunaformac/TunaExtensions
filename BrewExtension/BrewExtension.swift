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
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.79", minTunaKit: "1.12.0"),
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
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "browse-installed"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "browse-outdated"),
            DefaultActionIdentifier(
              catalogIdentifier: "brew.actions", actionID: "install-from-text"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "install-cask"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "update"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "upgrade-all"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "cleanup"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-available"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "install"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-installed"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "uninstall"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package-outdated"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "upgrade"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "uninstall"),
            DefaultActionIdentifier(catalogIdentifier: "brew.actions", actionID: "open-info"),
          ]
        ),
      ]
    )
  }
}
