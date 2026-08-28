import AppKit
import Foundation
import TunaKit

extension TypeID {
  static let poofSnippet = TypeID("com.tuna.type.poof-snippet")
  static let poofLibrary = TypeID("com.tuna.type.poof-library")
}

final class PoofSnippetItem: CatalogEntity, TextValueProviding, @unchecked Sendable {
  let record: PoofSnippetRecord

  var textValue: String { PoofSnippetRenderer.render(record.replacementTemplate) }

  init(record: PoofSnippetRecord) {
    self.record = record
    let title = record.details?.trimmingCharacters(in: .whitespacesAndNewlines)
    super.init(
      id: "\(record.sourceURL.path)#\(record.sourceIndex)",
      title: title?.isEmpty == false ? title! : record.trigger,
      path: record.sourceURL.path
    )
    typeID = .poofSnippet
  }

  override var detail: String? {
    let preview = record.replacementTemplate
      .replacingOccurrences(of: "\n", with: " ↩ ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return preview.isEmpty ? record.trigger : "\(record.trigger)  ·  \(preview)"
  }

  override var searchText: String {
    [title, record.trigger, record.replacementTemplate, record.details]
      .compactMap { $0 }
      .joined(separator: " ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("text.quote", tintColor: .systemRed)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

final class PoofLibraryItem: CatalogEntity, @unchecked Sendable {
  let directoryURL: URL
  var snippets: [CatalogItem] = []

  init(directoryURL: URL) {
    self.directoryURL = directoryURL
    super.init(id: "poof-library", title: "Poof Snippets", path: directoryURL.path)
    typeID = .poofLibrary
  }

  override var detail: String? { "Open or reveal Poof's snippet files" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: "text.quote", color: .red, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension PoofLibraryItem: CatalogHierarchyNode {
  func hierarchyChildren() -> [CatalogItem] { snippets }
}

enum PoofSnippetRenderer {
  static func render(
    _ template: String,
    now: Date = Date(),
    clipboard: @autoclosure () -> String = NSPasteboard.general.string(forType: .string) ?? "",
    uuid: @autoclosure () -> String = UUID().uuidString
  ) -> String {
    var output = ""
    var cursor = template.startIndex
    let clipboard = clipboard()
    let uuid = uuid()

    while let openRange = template[cursor...].range(of: "{{") {
      output += template[cursor..<openRange.lowerBound]
      guard let closeRange = template[openRange.upperBound...].range(of: "}}") else {
        output += template[openRange.lowerBound...]
        return output
      }
      let token = template[openRange.upperBound..<closeRange.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if token == "cursor" {
        // Tuna's generic Paste action cannot reposition another app's insertion point.
      } else {
        output += resolve(token, now: now, clipboard: clipboard, uuid: uuid)
      }
      cursor = closeRange.upperBound
    }

    output += template[cursor...]
    return output
  }

  private static func resolve(
    _ token: String,
    now: Date,
    clipboard: String,
    uuid: String
  ) -> String {
    switch token {
    case "date": return format(now, as: "yyyy-MM-dd")
    case "time": return format(now, as: "HH:mm")
    case "datetime": return format(now, as: "yyyy-MM-dd HH:mm")
    case "uuid": return uuid
    case "clipboard": return clipboard
    default:
      if token.hasPrefix("date:") {
        return format(now, as: String(token.dropFirst("date:".count)))
      }
      return "{{\(token)}}"
    }
  }

  private static func format(_ date: Date, as format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
