import AppKit
import Foundation
import TunaKit

/// Text first: text → Translate, or text → Translate To… → language.
/// Command first: Translate (to …) → Translate… → typed text.
public final class TranslateActionsCatalog: ActionCatalog {
  nonisolated static let translate = "translate"
  nonisolated static let translateTo = "translate-to"
  nonisolated static let translateText = "translate-text"

  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = [
    makeTranslate(), makeTranslateTo(), makeTranslateText(),
  ]

  private let translator: any Translating
  private let defaultLanguages: @MainActor () -> [TranslateLanguage]

  public required convenience init(definition: ActionCatalogDefinition) {
    self.init(
      definition: definition, translator: AppleTranslator(),
      defaultLanguages: { TranslateSettings.defaultLanguages })
  }

  init(
    definition: ActionCatalogDefinition, translator: any Translating,
    defaultLanguages: @escaping @MainActor () -> [TranslateLanguage]
  ) {
    identifier = definition.identifier
    name = definition.name
    self.translator = translator
    self.defaultLanguages = defaultLanguages
  }

  private func makeTranslate() -> CatalogAction {
    let translator = translator, defaultLanguages = defaultLanguages
    let action = PredicateAwareAction(id: Self.translate, title: "Translate") { subject, _ in
      await Self.translate(
        subject.textInputValue(), into: defaultLanguages(), hints: defaultLanguages(),
        translator: translator)
    }
    action.systemSymbolName = "translate"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = Self.hasText
    action.executionPolicy = .keepVisible
    return action
  }

  private func makeTranslateTo() -> CatalogAction {
    let translator = translator, defaultLanguages = defaultLanguages
    let action = PredicateAwareAction(id: Self.translateTo, title: "Translate To…") {
      subject, target in
      guard let language = (target as? TranslateLanguageItem)?.language else {
        return .failure("Choose a language")
      }
      return await Self.translate(
        subject.textInputValue(), into: [language], hints: defaultLanguages(),
        translator: translator)
    }
    action.systemSymbolName = "translate"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = Self.hasText
    action.targetRequirement = .required
    action.allowedTargetTypes = [.translateLanguage]
    action.targetPredicate = { $0 is TranslateLanguageItem }
    action.targetSearchScope = .catalogs(
      [TranslateExtension.languagesCatalogID], preparation: .loadIfNeeded)
    action.executionPolicy = .keepVisible
    return action
  }

  private func makeTranslateText() -> CatalogAction {
    let translator = translator, defaultLanguages = defaultLanguages
    let action = PredicateAwareAction(id: Self.translateText, title: "Translate…") {
      subject, target in
      guard let command = subject as? TranslateCommandItem else {
        return .failure("Choose a Translate command first")
      }
      return await Self.translate(
        target?.textInputValue(), into: command.language.map { [$0] } ?? defaultLanguages(),
        hints: defaultLanguages(), translator: translator)
    }
    action.systemSymbolName = "translate"
    action.supportedSubjectTypes = [.searchCatalogEntry]
    action.subjectPredicate = { $0 is TranslateCommandItem }
    action.targetRequirement = .required
    action.allowedTargetTypes = [.textSnippet]
    action.targetPredicate = Self.hasText
    action.targetTextSeedProvider = { _ in Self.clipboardText() }
    action.executionPolicy = .keepVisible
    return action
  }

  private static func hasText(_ item: CatalogItem?) -> Bool {
    item?.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  /// Detects the source language, then translates into each target, one result per target.
  /// A pair that can't be translated becomes an explanatory item instead of failing the rest.
  @MainActor
  static func translate(
    _ text: String?, into targets: [TranslateLanguage], hints: [TranslateLanguage],
    translator: any Translating
  ) async -> ActionResult {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return .failure("Type or select some text first")
    }
    guard let source = TranslateLanguage.detect(in: text, hints: hints + TranslateLanguage.preferred)
    else {
      return .results([TranslateMessages.item("Unknown language", "Couldn't tell which language this is.")])
    }
    let targets = targets.filter { $0 != source }
    guard !targets.isEmpty else {
      return .results([TranslateMessages.item("Already \(source.name)", "Choose another language with Translate To….")])
    }

    var items: [CatalogItem] = []
    for target in targets {
      if Task.isCancelled { return .cancelled }
      switch await translator.status(from: source, to: target) {
      case .unsupported:
        items.append(TranslateMessages.unsupported(from: source, to: target))
      case .notDownloaded:
        items.append(TranslateMessages.notDownloaded(from: source, to: target))
      case .installed:
        do {
          let translated = try await translator.translate(text, from: source, to: target)
          items.append(TranslationItem(text: translated, source: source, target: target))
        } catch TranslatorError.notDownloaded {
          items.append(TranslateMessages.notDownloaded(from: source, to: target))
        } catch TranslatorError.unsupported {
          items.append(TranslateMessages.unsupported(from: source, to: target))
        } catch {
          if Task.isCancelled { return .cancelled }
          items.append(
            TranslateMessages.item(
              "\(target.name) translation failed", error.localizedDescription))
        }
      }
    }
    return .results(items)
  }

  /// The clipboard text to start the typed-text box with, unless a password manager or similar
  /// marked it concealed or transient.
  @MainActor
  static func clipboardText(from pasteboard: NSPasteboard = .general) -> String? {
    let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    if pasteboard.types?.contains(where: { privateTypes.contains($0.rawValue) }) == true {
      return nil
    }
    let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }
}
