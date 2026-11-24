import Foundation
import TunaKit

@objc(HueExtension)
public final class HueExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Hue Control",
        author: "Benjamin Jesuiter",
        description: "Find Philips Hue rooms and zones and turn their lights on or off.",
        iconName: "lightbulb"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.113", minTunaKit: "1.23.0"),
      catalogs: [
        CatalogDeclaration(
          id: "hue.groups", type: HueCatalog.self, name: "Hue Groups",
          presentation: .source, enabledByDefault: true, initialGlobalScope: .all
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(id: "hue.actions", type: HueActions.self, name: "Hue Actions"),
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(typeID: .hueGroup, displayName: "Hue Groups", inheritsFrom: [.entity]),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .hueGroup,
        actions: ["check-connection", "on", "off"].map {
          ActionReference(catalogIdentifier: "hue.actions", actionID: $0)
        }
        ),
      ]
    )
  }
}
