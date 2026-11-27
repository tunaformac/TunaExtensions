import Foundation
import TunaKit

/// "Translate" plus "Translate to …" for each default language. The list follows the
/// Translate into setting and the Mac's preferred languages without a manual rescan.
@MainActor
public final class TranslateCommandsCatalog: Catalog {
  public let identifier: String
  public let name: String
  public private(set) var objects: [CatalogItem] = []

  private var languages: [TranslateLanguage] = []
  private var observers: [NSObjectProtocol] = []
  private let defaultLanguages: @MainActor () -> [TranslateLanguage]

  public convenience init(definition: CatalogDefinition) {
    self.init(definition: definition, defaultLanguages: { TranslateSettings.defaultLanguages })
  }

  init(
    definition: CatalogDefinition, defaultLanguages: @escaping @MainActor () -> [TranslateLanguage]
  ) {
    identifier = definition.identifier
    name = definition.name
    self.defaultLanguages = defaultLanguages
    rebuild()
    observers = [UserDefaults.didChangeNotification, NSLocale.currentLocaleDidChangeNotification]
      .map { notification in
        NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.rebuildIfLanguagesChanged() }
        }
      }
  }

  public func scan() async {
    rebuild()
    reportScanFinished()
  }

  private func rebuildIfLanguagesChanged() {
    guard defaultLanguages() != languages else { return }
    rebuild()
    reportScanFinished()
  }

  private func rebuild() {
    languages = defaultLanguages()
    objects = [TranslateAnyCommandItem()] + languages.map { TranslateCommandItem(language: $0) }
  }
}

/// Every language the Mac can translate, as the target list for Translate To….
@MainActor
public final class TranslateLanguagesCatalog: Catalog {
  /// Shared with the generic Translate entry's browse list.
  private(set) static var languages: [TranslateLanguage] = []

  public let identifier: String
  public let name: String
  public private(set) var objects: [CatalogItem] = []

  private let translator: any Translating

  public convenience init(definition: CatalogDefinition) {
    self.init(definition: definition, translator: AppleTranslator())
  }

  init(definition: CatalogDefinition, translator: any Translating) {
    identifier = definition.identifier
    name = definition.name
    self.translator = translator
  }

  public func scan() async {
    let languages = await translator.supportedLanguages()
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    Self.languages = languages
    objects = languages.map(TranslateLanguageItem.init)
    reportScanFinished()
  }
}
