import AppKit
import Foundation
import TunaKit

/// A translated text. It's a plain text snippet, so Copy, Paste, Large Type and every other
/// text action (including Translate again) apply to it.
final class TranslationItem: CatalogItem, TextValueProviding, @unchecked Sendable {
  let textValue: String
  let source: TranslateLanguage
  let target: TranslateLanguage

  init(text: String, source: TranslateLanguage, target: TranslateLanguage) {
    textValue = text
    self.source = source
    self.target = target
    super.init(id: "translate:\(source.identifier)>\(target.identifier):\(text)", title: text, type: .entity)
    typeID = .textSnippet
  }

  override var detail: String? { "\(target.name) · from \(source.name)" }
  override var searchKeys: [String] { [title, target.name] }
}

/// "Translate" (into every default language) or "Translate to German": the subject when you
/// start with the command and type the text second.
class TranslateCommandItem: CatalogEntity, ActionFilteringProviding, @unchecked Sendable {
  /// `nil` means the default languages.
  let language: TranslateLanguage?

  init(language: TranslateLanguage?) {
    self.language = language
    super.init(
      id: language.map { "translate.to.\($0.identifier)" } ?? "translate.command",
      title: language.map { "Translate to \($0.name)" } ?? "Translate",
      path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    if let language { return "Type text to translate into \(language.name)" }
    let names = TranslateSettings.defaultLanguages.map(\.name)
    return "Type text to translate into \(ListFormatter.localizedString(byJoining: names))"
  }

  override var searchKeys: [String] {
    guard let language else { return [title] }
    return [title, "Translate to \(language.nativeName)", "Translate to \(language.identifier)"]
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: "translate", color: .blue, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    catalogIdentifier == TranslateExtension.actionsCatalogID
      && action.id == TranslateActionsCatalog.translateText
  }
}

/// The generic "Translate" entry. Browsing into it lists "Translate to …" for every language
/// the Mac can translate, so languages outside your defaults are reachable command-first too.
final class TranslateAnyCommandItem: TranslateCommandItem, CatalogHierarchyNode, @unchecked Sendable {
  init() { super.init(language: nil) }

  @MainActor func hierarchyChildren() -> [CatalogItem] {
    let languages = TranslateLanguagesCatalog.languages
    return (languages.isEmpty ? TranslateSettings.defaultLanguages : languages)
      .map { TranslateCommandItem(language: $0) }
  }
}

/// A language to pick as the target of Translate To….
final class TranslateLanguageItem: CatalogEntity, @unchecked Sendable {
  let language: TranslateLanguage

  init(_ language: TranslateLanguage) {
    self.language = language
    super.init(id: "translate.language.\(language.identifier)", title: language.name, path: nil)
    typeID = .translateLanguage
  }

  override var detail: String? { language.nativeName }
  override var searchKeys: [String] { [title, language.nativeName, language.identifier] }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("globe", tintColor: .systemBlue)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

enum TranslateMessages {
  static func item(_ title: String, _ message: String) -> CatalogItem {
    CatalogMessageItem(
      title: title, message: message, symbolName: "exclamationmark.bubble",
      tintColor: .systemOrange)
  }

  /// Opens Language & Region, where Translation Languages are downloaded.
  static func notDownloaded(from source: TranslateLanguage, to target: TranslateLanguage)
    -> CatalogItem
  {
    CommandItem(
      id: "translate.download.\(source.identifier)>\(target.identifier)",
      title: "\(source.name) → \(target.name) isn't downloaded",
      symbol: "arrow.down.circle",
      detail: "Open Language & Region, then Translation Languages, to download it",
      tintColor: .systemOrange,
      headlessEligibility: .guaranteed,
      executionPolicy: .dismiss
    ) {
      let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
      return NSWorkspace.shared.open(url) ? .success : .failure("Couldn't open System Settings")
    }
  }
}
