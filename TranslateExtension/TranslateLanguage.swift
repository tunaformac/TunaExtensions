import Foundation
import NaturalLanguage

/// A translation language reduced to its language code plus a script only where the script
/// matters: `de`, `en`, `zh-Hant`. Regions are dropped, so `en-DE` and `en-US` are both `en`.
struct TranslateLanguage: Hashable, Sendable {
  let identifier: String

  init?(_ raw: String) {
    let language = Locale.Language(identifier: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let code = language.languageCode, code.isISOLanguage else { return nil }
    let defaultScript = Locale.Language(
      identifier: Locale.Language(identifier: code.identifier).maximalIdentifier
    ).script
    if let script = language.script, script != defaultScript {
      identifier = "\(code.identifier)-\(script.identifier)"
    } else {
      identifier = code.identifier
    }
  }

  var localeLanguage: Locale.Language { Locale.Language(identifier: identifier) }

  /// The name in the Mac's own language, e.g. "German".
  var name: String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }

  /// The name in the language itself, e.g. "Deutsch", so either spelling finds it.
  var nativeName: String {
    Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
  }

  /// Parses a list such as "de, en zh-Hant", skipping unknown codes and repeats.
  static func list(_ text: String) -> [TranslateLanguage] {
    var seen = Set<TranslateLanguage>()
    return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
      .compactMap { TranslateLanguage(String($0)) }
      .filter { seen.insert($0).inserted }
  }

  /// The Mac's preferred languages from System Settings → General → Language & Region.
  static var preferred: [TranslateLanguage] { list(Locale.preferredLanguages.joined(separator: ",")) }

  /// Detects the language of `text`. Single words are often ambiguous ("squirrel" alone reads as
  /// Catalan), so the user's own languages are given as hints.
  static func detect(in text: String, hints: [TranslateLanguage]) -> TranslateLanguage? {
    let recognizer = NLLanguageRecognizer()
    if !hints.isEmpty {
      let weight = 1.0 / Double(hints.count)
      recognizer.languageHints = Dictionary(
        hints.map { (NLLanguage(rawValue: $0.identifier), weight) }, uniquingKeysWith: { a, _ in a })
    }
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
    return TranslateLanguage(language.rawValue)
  }
}
