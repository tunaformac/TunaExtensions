import Foundation
import Translation

enum TranslationPairStatus: Sendable {
  case installed
  case notDownloaded
  case unsupported
}

/// The boundary to Apple's Translation framework, so tests can swap in a stub.
protocol Translating: Sendable {
  func supportedLanguages() async -> [TranslateLanguage]
  func status(from source: TranslateLanguage, to target: TranslateLanguage) async
    -> TranslationPairStatus
  func translate(_ text: String, from source: TranslateLanguage, to target: TranslateLanguage)
    async throws -> String
}

/// Apple's on-device translation. Nothing leaves the Mac, and only language pairs the user has
/// already downloaded can be used: the download sheet needs a SwiftUI window Tuna doesn't have.
struct AppleTranslator: Translating {
  func supportedLanguages() async -> [TranslateLanguage] {
    let languages = await LanguageAvailability().supportedLanguages
    return TranslateLanguage.list(languages.map(\.maximalIdentifier).joined(separator: ","))
  }

  func status(from source: TranslateLanguage, to target: TranslateLanguage) async
    -> TranslationPairStatus
  {
    switch await LanguageAvailability().status(
      from: source.localeLanguage, to: target.localeLanguage)
    {
    case .installed: return .installed
    case .supported: return .notDownloaded
    case .unsupported: return .unsupported
    @unknown default: return .unsupported
    }
  }

  func translate(_ text: String, from source: TranslateLanguage, to target: TranslateLanguage)
    async throws -> String
  {
    guard #available(macOS 26.0, *) else { throw TranslateError.needsNewerMacOS }
    let session = TranslationSession(
      installedSource: source.localeLanguage, target: target.localeLanguage)
    return try await session.translate(text).targetText
  }
}

enum TranslateError: LocalizedError {
  case needsNewerMacOS

  var errorDescription: String? { "Translate needs macOS 26 or later." }
}
