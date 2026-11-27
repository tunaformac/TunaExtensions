import AppKit
import Foundation
import TunaKit
import XCTest

@testable import TranslateExtension

/// Stands in for Apple's Translation framework: every pair is installed unless listed otherwise,
/// and a translation is the target code plus the text.
private struct StubTranslator: Translating {
  var statuses: [String: TranslationPairStatus] = [:]
  /// Pairs whose status says installed but whose translation fails, like a pack removed in between.
  var failures: [String: TranslatorError] = [:]
  /// Cancels the running task during the first translation, like Escape in Tuna.
  var cancelsWhileTranslating = false

  func supportedLanguages() async -> [TranslateLanguage] { TranslateLanguage.list("en, de, fr") }

  func status(from source: TranslateLanguage, to target: TranslateLanguage) async
    -> TranslationPairStatus
  {
    statuses["\(source.identifier)>\(target.identifier)"] ?? .installed
  }

  func translate(_ text: String, from source: TranslateLanguage, to target: TranslateLanguage)
    async throws -> String
  {
    if let failure = failures["\(source.identifier)>\(target.identifier)"] { throw failure }
    if cancelsWhileTranslating { withUnsafeCurrentTask { $0?.cancel() } }
    return "[\(target.identifier)] \(text)"
  }
}

@MainActor
final class TranslateExtensionTests: XCTestCase {
  private let english = TranslateLanguage("en")!
  private let german = TranslateLanguage("de")!

  private func catalog(_ translator: StubTranslator = StubTranslator()) -> TranslateActionsCatalog {
    TranslateActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.translate.actions", name: "Actions"),
      translator: translator, defaultLanguages: { TranslateLanguage.list("en, de") })
  }

  private func action(_ id: String, in catalog: TranslateActionsCatalog) throws
    -> PredicateAwareAction
  {
    try XCTUnwrap(catalog.actions.first { $0.id == id } as? PredicateAwareAction)
  }

  private func results(_ result: ActionResult) throws -> [CatalogItem] {
    guard case .results(let items) = result else {
      XCTFail("Expected listed results, got \(result)")
      return []
    }
    return items
  }

  func testDeclarationIsValid() throws {
    let bundle = Bundle(for: TranslateExtension.self)
    let declaration = try XCTUnwrap(
      try TranslateExtension(bundle: bundle).declaration)
    try declaration.validate()
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.96")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.22.0")
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "26.0")
  }

  func testLanguageListsDropRegionsKeepMeaningfulScriptsAndSkipJunk() {
    XCTAssertEqual(
      TranslateLanguage.list("en-DE, de-DE;zh-Hant-DE zh-Hans en xx-nope ,, de").map(\.identifier),
      ["en", "de", "zh-Hant", "zh"])
  }

  func testDetectionUsesHintsForSingleWords() {
    let hints = [english, german]
    XCTAssertEqual(TranslateLanguage.detect(in: "squirrel", hints: hints), english)
    XCTAssertEqual(TranslateLanguage.detect(in: "Eichhörnchen", hints: hints), german)
    XCTAssertNil(TranslateLanguage.detect(in: "1234", hints: hints))
  }

  /// Full sentences in a language you don't have are detected as that language, not forced into
  /// one of your own.
  func testDetectionDoesNotForceSentencesIntoHintLanguages() {
    let sentences = [
      "fr": "Bonjour, je voudrais un café s'il vous plaît.",
      "es": "¿Dónde está la estación de tren?",
      "it": "Vorrei prenotare un tavolo per due persone stasera.",
      "nl": "Ik wil graag een kopje koffie bestellen, alstublieft.",
      "sv": "Jag skulle vilja beställa en kopp kaffe, tack.",
      "pt": "Eu gostaria de pedir um café, por favor.",
    ]
    for hints in [[english], [english, german]] {
      for (expected, sentence) in sentences {
        XCTAssertEqual(
          TranslateLanguage.detect(in: sentence, hints: hints)?.identifier, expected,
          "\(sentence) with hints \(hints.map(\.identifier))")
      }
    }
  }

  func testTranslateGivesOneResultPerDefaultLanguageExceptTheSource() async throws {
    let translate = try action(TranslateActionsCatalog.translate, in: catalog())
    XCTAssertEqual(translate.supportedSubjectTypes, [.textSnippet])
    XCTAssertEqual(translate.targetRequirement, .none)

    let items = try results(await translate.callback(TextSnippetItem(text: "squirrel"), nil))
    let item = try XCTUnwrap(items.first as? TranslationItem)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(item.textValue, "[de] squirrel")
    XCTAssertEqual(item.detail, "German · from English")
    XCTAssertEqual(item.typeID, .textSnippet)
  }

  func testTranslateDetectsAForeignSentenceAndTranslatesIntoEveryDefault() async throws {
    let translate = try action(TranslateActionsCatalog.translate, in: catalog())
    let items = try results(
      await translate.callback(
        TextSnippetItem(text: "Bonjour, je voudrais un café s'il vous plaît."), nil))
    XCTAssertEqual(
      items.map(\.detail), ["English · from French", "German · from French"])
  }

  func testTranslateToTakesARequiredLanguageFromTheLanguagesCatalog() async throws {
    let translateTo = try action(TranslateActionsCatalog.translateTo, in: catalog())
    XCTAssertEqual(translateTo.targetRequirement, .required)
    XCTAssertEqual(translateTo.allowedTargetTypes, [.translateLanguage])
    XCTAssertEqual(
      translateTo.targetSearchScope.catalogIdentifiers, [TranslateExtension.languagesCatalogID])

    let french = TranslateLanguageItem(TranslateLanguage("fr")!)
    let items = try results(await translateTo.callback(TextSnippetItem(text: "squirrel"), french))
    XCTAssertEqual((items.first as? TranslationItem)?.textValue, "[fr] squirrel")
  }

  func testCommandFirstTranslatesTheTypedText() async throws {
    let translateText = try action(TranslateActionsCatalog.translateText, in: catalog())
    XCTAssertEqual(translateText.targetRequirement, .required)
    XCTAssertEqual(translateText.allowedTargetTypes, [.textSnippet])
    XCTAssertNotNil(translateText.targetTextSeedProvider)

    let toGerman = TranslateCommandItem(language: german)
    XCTAssertEqual(toGerman.title, "Translate to German")
    XCTAssertTrue(
      toGerman.allowsAction(translateText, catalogIdentifier: TranslateExtension.actionsCatalogID))
    XCTAssertFalse(toGerman.allowsAction(translateText, catalogIdentifier: "other.actions"))

    let one = try results(await translateText.callback(toGerman, TextSnippetItem(text: "squirrel")))
    XCTAssertEqual(one.compactMap { ($0 as? TranslationItem)?.textValue }, ["[de] squirrel"])

    let any = try results(
      await translateText.callback(TranslateAnyCommandItem(), TextSnippetItem(text: "Eichhörnchen")))
    XCTAssertEqual(any.compactMap { ($0 as? TranslationItem)?.textValue }, ["[en] Eichhörnchen"])
  }

  func testPairsThatCantBeTranslatedBecomeExplanationsWithoutStoppingTheRest() async throws {
    let translator = StubTranslator(statuses: ["en>de": .notDownloaded, "en>fr": .unsupported])
    let catalog = TranslateActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.translate.actions", name: "Actions"),
      translator: translator, defaultLanguages: { TranslateLanguage.list("de, fr, es") })
    let translate = try action(TranslateActionsCatalog.translate, in: catalog)

    let items = try results(await translate.callback(TextSnippetItem(text: "the squirrel"), nil))
    XCTAssertEqual(items.count, 3)
    XCTAssertTrue(items[0] is CommandItem)
    XCTAssertEqual(items[0].title, "English → German isn't downloaded")
    XCTAssertEqual(items[1].title, "Can't translate English to French")
    XCTAssertEqual((items[2] as? TranslationItem)?.textValue, "[es] the squirrel")
  }

  func testPairsThatFailWhileTranslatingAreExplainedLikeTheStatusCheck() async throws {
    let translator = StubTranslator(failures: ["en>de": .notDownloaded, "en>fr": .unsupported])
    let catalog = TranslateActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.translate.actions", name: "Actions"),
      translator: translator, defaultLanguages: { TranslateLanguage.list("de, fr") })
    let translate = try action(TranslateActionsCatalog.translate, in: catalog)

    let items = try results(await translate.callback(TextSnippetItem(text: "the squirrel"), nil))
    XCTAssertEqual(
      items.map(\.title),
      ["English → German isn't downloaded", "Can't translate English to French"])
  }

  func testCancellingStopsBeforeTheNextTarget() async throws {
    let catalog = TranslateActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "test.translate.actions", name: "Actions"),
      translator: StubTranslator(cancelsWhileTranslating: true),
      defaultLanguages: { TranslateLanguage.list("de, fr") })
    let translate = try action(TranslateActionsCatalog.translate, in: catalog)

    guard case .cancelled = await translate.callback(TextSnippetItem(text: "the squirrel"), nil)
    else { return XCTFail("Expected the cancelled translation to stop") }
  }

  func testTextAlreadyInTheOnlyTargetSaysSo() async throws {
    let translateTo = try action(TranslateActionsCatalog.translateTo, in: catalog())
    let items = try results(
      await translateTo.callback(
        TextSnippetItem(text: "Wie geht es dir heute?"), TranslateLanguageItem(german)))
    XCTAssertEqual(items.map(\.title), ["Already German"])
  }

  func testEmptyTextIsRejected() async throws {
    let translate = try action(TranslateActionsCatalog.translate, in: catalog())
    XCTAssertFalse(try XCTUnwrap(translate.subjectPredicate)(TextSnippetItem(text: "  ")))
    guard case .failure = await translate.callback(TextSnippetItem(text: " "), nil) else {
      return XCTFail("Expected a failure for empty text")
    }
  }

  func testClipboardSeedSkipsConcealedText() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("  squirrel \n", forType: .string)
    XCTAssertEqual(TranslateActionsCatalog.clipboardText(from: pasteboard), "squirrel")

    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    pasteboard.declareTypes([.string, concealed], owner: nil)
    pasteboard.setString("hunter2", forType: .string)
    XCTAssertNil(TranslateActionsCatalog.clipboardText(from: pasteboard))
  }

  func testLanguagesCatalogListsSupportedLanguagesByName() async {
    let languages = TranslateLanguagesCatalog(
      definition: CatalogDefinition(
        identifier: TranslateExtension.languagesCatalogID, name: "Languages",
        enabledByDefault: true, initialGlobalScope: .none, settings: []),
      translator: StubTranslator())
    await languages.scan()
    XCTAssertEqual(languages.objects.map(\.title), ["English", "French", "German"])
    XCTAssertEqual(languages.objects.first?.typeID, .translateLanguage)
  }
}
