import Foundation
import TunaKit

@objc(TranslateExtension)
public final class TranslateExtension: Extension {
  static let commandsCatalogID = "translate.commands"
  static let languagesCatalogID = "translate.languages"
  nonisolated static let actionsCatalogID = "translate.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Translate",
        author: "Denis Maier",
        description: """
          Translate text with Apple's on-device translation.

          If you only need a hotkey for one language or want to add translation to an existing \
          shortcut, use Apple's Translate Text action. In Tuna, choose Send to Shortcut… \
          to pass selected text.
          """,
        iconName: "translate"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: TranslateSettings.definitions,
      catalogs: [
        // "Translate" and one "Translate to …" per default language: the command-first entries.
        CatalogDeclaration(
          id: Self.commandsCatalogID,
          type: TranslateCommandsCatalog.self,
          name: "Translate",
          presentation: .source,
          description: "Translate, plus Translate to … for each language you translate into",
          enabledByDefault: true,
          initialGlobalScope: .all
        ),
        // Only the target list for Translate To…; languages stay out of global search.
        CatalogDeclaration(
          id: Self.languagesCatalogID,
          type: TranslateLanguagesCatalog.self,
          name: "Translation Languages",
          presentation: .source,
          description: "Languages to choose from in Translate To…",
          enabledByDefault: true,
          initialGlobalScope: .none
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogID,
          type: TranslateActionsCatalog.self,
          name: "Translate Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .translateLanguage, displayName: "Translation Languages", inheritsFrom: [.entity])
      ]
    )
  }
}

enum TranslateSettings {
  static let translateInto = CatalogSettingDefinition(
    key: "TranslateInto",
    type: .string,
    label: "Translate into",
    defaultValue: "",
    description:
      "Language codes separated by commas, for example de, en-GB, zh-Hant. Leave empty to use your Mac's preferred languages from Language & Region."
  )

  static let definitions = [translateInto]

  /// The languages Translate uses when you don't pick one.
  static var defaultLanguages: [TranslateLanguage] {
    let chosen = TranslateLanguage.list(
      store.stringValue(for: translateInto), keepingRegions: true)
    return chosen.isEmpty ? TranslateLanguage.preferred : chosen
  }

  private static var store: CatalogSettingStore {
    let bundle = Bundle(for: TranslateExtension.self)
    return CatalogSettingStore(
      catalogIdentifier: bundle.bundleIdentifier ?? "com.brnbw.tuna.plugins.translate")
  }
}

extension TypeID {
  static let translateLanguage = TypeID("com.tuna.type.translation-language")
}
