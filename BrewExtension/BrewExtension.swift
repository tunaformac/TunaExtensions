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
      compatibility: ExtensionDeclarationCompatibility(minTunaKit: "1.11.0"),
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
          typeID: TypeID("com.tuna.type.brew-package.available"),
          displayName: "Available Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package.installed"),
          displayName: "Installed Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
        TypeRegistrationDefinition(
          typeID: TypeID("com.tuna.type.brew-package.outdated"),
          displayName: "Outdated Homebrew Packages",
          inheritsFrom: [TypeID("com.tuna.type.brew-package")]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-meta"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "browse-installed"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "browse-outdated"),
            DefaultActionIdentifier(
              catalogIdentifier: "brew.search", actionID: "install.from-text"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "install-cask"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "update"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "upgrade-all"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "cleanup"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package.available"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "install"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package.installed"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "uninstall"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "open-info"),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: TypeID("com.tuna.type.brew-package.outdated"),
          actions: [
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "upgrade"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "uninstall"),
            DefaultActionIdentifier(catalogIdentifier: "brew.search", actionID: "open-info"),
          ]
        ),
      ]
    )
  }
}
