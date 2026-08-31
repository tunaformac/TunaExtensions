import AppKit
import Foundation
import TunaKit

enum AuthenticationCodeExtractor {
  static func extract(from original: String) -> String? {
    guard !original.isEmpty else { return nil }
    var message = replacing(#"\b(?:https?|ftp|file)://\S+|\bwww\.\S+"#, in: original, with: "")
    message = replacing(#"\b(?:\+?\d[\d .()-]{7,}\d|\d{3}[-. ]\d{4})\b"#, in: message, with: "")
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

    if let groups = firstCaptures(#"(?i)\b(\d{3})-(\d{3})\b"#, in: message), groups.count == 2 {
      return groups.joined()
    }

    let contextualPatterns = [
      #"(?i)(?:code\s*[:：]?|is\s*[:：]|use code\s*|passcode\s*[:：]|码\s*|autoriza(?:ca|çã)o\s*[:：]|c(?:o|ó)digo\s*[:：])\s*([A-Z0-9]{3,8})\b"#,
      #"(?i)\b([A-Z0-9]{3,8})\s+is your[^\n]*code\b"#,
    ]
    for pattern in contextualPatterns {
      if let value = lastCapture(pattern, in: message) { return value }
    }

    if let value = firstMatch(#"\b\d{5,8}\b"#, in: message) { return value }
    if let value = firstMatch(#"\b(?=[A-Z0-9]{3,8}\b)(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{3,8}\b"#, in: message) {
      return value
    }
    return nil
  }

  private static func replacing(_ pattern: String, in string: String, with replacement: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
    let range = NSRange(string.startIndex..., in: string)
    return regex.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
  }

  private static func firstMatch(_ pattern: String, in string: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let match = regex.firstMatch(in: string, range: range),
      let matchRange = Range(match.range, in: string)
    else { return nil }
    return String(string[matchRange])
  }

  private static func firstCaptures(_ pattern: String, in string: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let match = regex.firstMatch(in: string, range: range) else { return nil }
    return (1..<match.numberOfRanges).compactMap { index in
      Range(match.range(at: index), in: string).map { String(string[$0]) }
    }
  }

  private static func lastCapture(_ pattern: String, in string: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    return regex.matches(in: string, range: range).last.flatMap { match in
      Range(match.range(at: 1), in: string).map { String(string[$0]) }
    }
  }
}

final class AuthenticationCodeItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  @unchecked Sendable
{
  let textValue: String
  let sender: String
  let capturedAtDate: Date

  init?(message: MessagesDatabase.Message) {
    guard let code = AuthenticationCodeExtractor.extract(from: message.body) else { return nil }
    self.textValue = code
    self.sender = message.sender
    self.capturedAtDate = message.receivedAt
    super.init(id: "\(message.guid):\(code)", title: code, path: nil)
    typeID = .authenticationCode
  }

  override var detail: String? {
    "\(sender) · \(capturedAtDate.formatted(.relative(presentation: .named)))"
  }

  override var searchText: String { "\(textValue) \(sender)" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("message.fill", tintColor: .systemGreen)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}
