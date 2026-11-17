import Foundation
import TunaKit

@objc(OpenTerminalHereExtension)
public final class OpenTerminalHereExtension: Extension {
  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Open Terminal Here",
        author: "Zachary Yocum",
        description: "Open a folder, or the folder containing a file, in your terminal.",
        iconName: "terminal"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.108", minTunaKit: "1.22.0"),
      settings: OpenTerminalHereSettings.definitions,
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: "open-terminal-here.actions",
          type: OpenTerminalHereActionsCatalog.self,
          name: "Open Terminal Here Actions"
        )
      ]
    )
  }
}

enum OpenTerminalHereSettings {
  static let terminal = CatalogSettingDefinition(
    key: "Terminal",
    type: .string,
    label: "Terminal",
    defaultValue: TerminalApp.terminal.id,
    description:
      "The app Open Terminal Here opens. Tuna shows an error if it is not installed instead of using another app.",
    options: TerminalApp.all.map { .init(value: $0.id, label: $0.name) }
  )

  static let definitions = [terminal]

  static var currentTerminalID: String {
    let bundle = Bundle(for: OpenTerminalHereExtension.self)
    let identifier = bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaOpenTerminalHere")
    return CatalogSettingStore(catalogIdentifier: identifier).stringValue(for: terminal)
  }
}
