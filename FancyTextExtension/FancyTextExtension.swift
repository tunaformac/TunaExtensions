import Foundation
import TunaKit

@objc(FancyTextExtension)
public final class FancyTextExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Fancy Text",
        author: "Pedro Duarte & contributors",
        description: "Turn ordinary text into playful Unicode styles.",
        iconName: "wand.and.sparkles"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.94", minTunaKit: "1.20.0"),
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "fancy-text.actions",
          type: FancyTextActionsCatalog.self,
          name: "Fancy Text Actions"
        )
      ]
    )
  }
}
