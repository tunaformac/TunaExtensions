import Foundation
import TunaKit

@objc(SpeedtestExtension)
public final class SpeedtestExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Speedtest",
        author: "Tuna",
        description: "Test your internet speed with macOS networkQuality.",
        iconName: "speedometer"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.113", minTunaKit: "1.22.0"),
      catalogs: [
        CatalogDeclaration(
          id: "speedtest", type: SpeedtestCatalog.self, name: "Speedtest",
          presentation: .source, enabledByDefault: true, initialGlobalScope: .all)
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "speedtest.actions", type: SpeedtestActionsCatalog.self, name: "Speedtest Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .speedtestResult, displayName: "Speed Test Results",
          inheritsFrom: [.textSnippet])
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .speedtestResult,
          actions: [
            ActionReference(catalogIdentifier: "speedtest.actions", actionID: "copy-summary")
          ]
        )
      ]
    )
  }
}

extension TypeID {
  static let speedtestResult = TypeID("com.tuna.type.speedtest-result")
}
