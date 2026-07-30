import AppKit
import Foundation
import TunaKit

struct NotionConnection: Sendable {
  let record: ExtensionConnectionRecord
  let accessToken: String

  var displayName: String {
    record.trimmedDisplayName
  }
}

enum NotionCatalogSupport {
  static let providerIdentifier = "notion"

  static let connectionDefinition = ExtensionConnectionDefinition(
    providerIdentifier: providerIdentifier,
    providerName: "Notion",
    kind: .oauth,
    description:
      "Connect one or more Notion workspaces using Notion OAuth. Each authorized workspace is stored as its own connection.",
    connectButtonLabel: "Connect Notion"
  )

  static func connections(for type: AnyClass) -> [NotionConnection] {
    guard let bundleIdentifier = Bundle(for: type).bundleIdentifier else { return [] }
    let store = ExtensionConnectionStore(
      extensionIdentifier: bundleIdentifier,
      providerIdentifier: providerIdentifier
    )

    return store.orderedRecords().compactMap { record in
      guard
        let accessToken = store.accessToken(for: record)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !accessToken.isEmpty
      else { return nil }

      return NotionConnection(record: record, accessToken: accessToken)
    }
  }

  static func authRequiredMessageItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Connect Notion",
      message:
        "Add at least one Notion connection in extension settings to browse and search shared pages.",
      symbolName: "book.pages",
      tintColor: .systemOrange
    )
  }

  static func emptyStateItem(title: String, message: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: title,
      message: message,
      symbolName: "tray",
      tintColor: .secondaryLabelColor
    )
  }

  static func loadingItem() -> CatalogLoadingItem {
    CatalogLoadingItem(
      title: "Loading Notion",
      message: "Fetching shared Notion pages and data sources."
    )
  }

  static func messageItem(for error: Error) -> CatalogMessageItem {
    if let error = error as? NotionAPIError {
      return CatalogMessageItem(
        title: error.title,
        message: error.localizedDescription,
        symbolName: "exclamationmark.triangle",
        tintColor: .systemOrange
      )
    }

    return CatalogMessageItem(
      title: "Notion request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func relativeDateString(from date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  static func detail(
    for item: NotionItem,
    connection: NotionConnection,
    totalConnections: Int
  ) -> String {
    var parts: [String] = []
    if totalConnections > 1 {
      parts.append(connection.displayName)
    }
    parts.append(item.kind.displayName)
    if let edited = relativeDateString(from: item.lastEditedAt) {
      parts.append("Edited \(edited)")
    }
    return parts.joined(separator: " · ")
  }

  static func loadPerConnection<Payload: Sendable>(
    _ connections: [NotionConnection],
    operation: @escaping @Sendable (NotionConnection) async throws -> Payload
  ) async throws -> [(offset: Int, connection: NotionConnection, payload: Payload)] {
    try await withThrowingTaskGroup(
      of: (offset: Int, connection: NotionConnection, payload: Payload).self
    ) { group in
      for (offset, connection) in connections.enumerated() {
        group.addTask {
          (offset, connection, try await operation(connection))
        }
      }

      var results: [(offset: Int, connection: NotionConnection, payload: Payload)] = []
      for try await result in group {
        results.append(result)
      }
      return results.sorted { $0.offset < $1.offset }
    }
  }

  static func catalogItems(
    from connectionResults: [(offset: Int, connection: NotionConnection, payload: [NotionItem])],
    totalConnections: Int
  ) -> [CatalogItem] {
    connectionResults
      .flatMap { result in
        result.payload.map { item in
          (offset: result.offset, connection: result.connection, item: item)
        }
      }
      .sorted(by: isMoreRecent)
      .map { result in
        NotionResultItem(
          item: result.item,
          detail: detail(
            for: result.item,
            connection: result.connection,
            totalConnections: totalConnections
          )
        )
      }
  }

  private static func isMoreRecent(
    _ lhs: (offset: Int, connection: NotionConnection, item: NotionItem),
    _ rhs: (offset: Int, connection: NotionConnection, item: NotionItem)
  ) -> Bool {
    let lhsDate = lhs.item.lastEditedAt ?? .distantPast
    let rhsDate = rhs.item.lastEditedAt ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }

    let titleComparison = lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title)
    if titleComparison != .orderedSame {
      return titleComparison == .orderedAscending
    }

    if lhs.offset != rhs.offset {
      return lhs.offset < rhs.offset
    }

    return lhs.item.id < rhs.item.id
  }

  static func scan(
    for catalogType: AnyClass,
    identifier: String,
    messageStore: LockedValue<[CatalogItem]?>,
    onMissingConnections: () -> Void = {},
    onError: () -> Void = {},
    work: ([NotionConnection]) async throws -> Void
  ) async {
    let connections = connections(for: catalogType)
    guard !connections.isEmpty else {
      messageStore.value = [authRequiredMessageItem()]
      onMissingConnections()
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
      return
    }

    do {
      try await work(connections)
      messageStore.value = nil
    } catch {
      onError()
      messageStore.value = [messageItem(for: error)]
    }

    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }
}

final class NotionResultItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  CatalogAsyncPreviewProviding, @unchecked Sendable
{
  private let detailText: String
  private let symbolName: String
  private let notionIcon: NotionItem.Icon?
  let capturedAtDate: Date

  var textValue: String { path ?? title }

  init(item: NotionItem, detail: String) {
    self.detailText = detail
    self.symbolName = item.kind.symbolName
    self.notionIcon = item.icon
    self.capturedAtDate = item.lastEditedAt ?? .distantPast
    super.init(id: item.url.absoluteString, title: item.title, path: item.url.absoluteString)
    typeID = .url
  }

  override var detail: String? {
    detailText
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    if case .emoji(let emoji) = notionIcon,
      let image = NotionIconPreviewRenderer.emojiImage(emoji, maxDimension: maxDimension)
    {
      return CatalogItemPreview(image: image)
    }

    return CatalogItemPreview.systemSymbol(symbolName)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    guard case .imageURL(let url) = notionIcon else { return nil }
    return await NotionIconImageLoader.shared.preview(for: url, maxDimension: maxDimension)
  }

}

private enum NotionIconPreviewRenderer {
  static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }

    let dominant = max(image.size.width, image.size.height)
    guard dominant > 0 else { return nil }

    let scale = maxDimension / dominant
    let targetSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let scaled = NSImage(size: targetSize)
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
      in: NSRect(origin: .zero, size: targetSize),
      from: NSRect(origin: .zero, size: image.size),
      operation: .copy,
      fraction: 1.0,
      respectFlipped: true,
      hints: nil
    )
    scaled.unlockFocus()
    return scaled
  }

  static func emojiImage(_ emoji: String, maxDimension: CGFloat) -> NSImage? {
    let side = max(1, Int(ceil(maxDimension)))
    let size = NSSize(width: side, height: side)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: CGFloat(side) * 0.72)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .paragraphStyle: paragraph,
    ]
    let textSize = emoji.size(withAttributes: attributes)
    let rect = NSRect(
      x: 0,
      y: (size.height - textSize.height) / 2,
      width: size.width,
      height: textSize.height
    )
    emoji.draw(in: rect, withAttributes: attributes)
    return image
  }
}

private actor NotionIconImageLoader {
  static let shared = NotionIconImageLoader()

  private let session = URLSession(configuration: .ephemeral)
  private var cache: [URL: Data?] = [:]

  func preview(for url: URL, maxDimension: CGFloat) async -> CatalogItemPreview? {
    let data: Data?
    if let cached = cache[url] {
      data = cached
    } else {
      data = await fetchImageData(url)
      cache[url] = data
    }

    guard let data, let image = NSImage(data: data) else { return nil }
    return CatalogItemPreview(
      image: NotionIconPreviewRenderer.scaledImage(image, maxDimension: maxDimension) ?? image
    )
  }

  private func fetchImageData(_ url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

    guard
      let (data, response) = try? await session.data(for: request),
      let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      httpResponse.mimeType?.hasPrefix("image/") != false,
      NSImage(data: data) != nil
    else { return nil }

    return data
  }
}
