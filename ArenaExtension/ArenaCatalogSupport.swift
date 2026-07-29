import AppKit
import Foundation
import TunaKit

enum ArenaCatalogSupport {
  static let providerIdentifier = "arena"

  static func connections(for type: AnyClass) -> [ArenaConnection] {
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
      return ArenaConnection(record: record, accessToken: accessToken)
    }
  }

  static func authRequiredItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Connect Are.na",
      message: "Connect Are.na in extension settings to browse your channels.",
      symbolName: "square.grid.2x2",
      tintColor: .systemOrange
    )
  }

  static func loadingItem(_ subject: String = "Are.na") -> CatalogLoadingItem {
    CatalogLoadingItem(
      title: "Loading \(subject)",
      message: "Fetching content from Are.na."
    )
  }

  static func emptyItem(title: String, message: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: title,
      message: message,
      symbolName: "tray",
      tintColor: .secondaryLabelColor
    )
  }

  static func errorItem(_ error: Error) -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Are.na request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }
}

final class ArenaChannelItem: CatalogEntity, CatalogHierarchyNode, CatalogHierarchyViewProviding,
  TimestampedCatalogItem, @unchecked Sendable
{
  let channel: ArenaChannel
  let connection: ArenaConnection
  let capturedAtDate: Date

  private let catalogIdentifier: String
  private let childrenStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let loadState = DeferredCatalogLoadState()
  private let loadTask = LockedValue<Task<Void, Never>?>(nil)

  var childResultsPresentation: CatalogResultsPresentation {
    .grid(
      CatalogGridConfiguration(
        columns: 4,
        minimumCellSize: 88,
        maximumCellSize: 140,
        spacing: 4,
        padding: 4,
        cellPadding: 8
      )
    )
  }

  init(channel: ArenaChannel, connection: ArenaConnection, catalogIdentifier: String) {
    self.channel = channel
    self.connection = connection
    self.catalogIdentifier = catalogIdentifier
    capturedAtDate = channel.updatedAt ?? .distantPast
    super.init(
      id: "arena.channel.\(connection.record.id).\(channel.id)",
      title: channel.title,
      path: channel.url.absoluteString
    )
    typeID = .arenaChannel
  }

  override var detail: String? {
    channel.visibility.capitalized
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("square.grid.2x2")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return message }

    loadState.requestLoadIfNeeded { [weak self] in self?.loadContents() }
    let children = childrenStore.readValue { $0 }
    if !children.isEmpty || loadState.didCompleteLoad { return children }
    return [ArenaCatalogSupport.loadingItem(channel.title)]
  }

  private func loadContents() {
    loadTask.withValue { task in
      guard task == nil else { return }
      let connection = connection
      let channel = channel
      task = Task { [weak self] in
        guard let self else { return }
        do {
          let blocks = try await ArenaAPIClient(connection: connection).fetchContents(
            channelSlug: channel.slug)
          childrenStore.value = blocks.isEmpty
            ? [
              ArenaCatalogSupport.emptyItem(
                title: "Empty channel", message: "This Are.na channel has no blocks yet.")
            ]
            : blocks.map { ArenaBlockItem(block: $0, connectionID: connection.record.id) }
          messageStore.value = nil
        } catch {
          childrenStore.value = []
          messageStore.value = [ArenaCatalogSupport.errorItem(error)]
        }
        loadState.markLoadCompleted()
        loadTask.value = nil
        NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
      }
    }
  }
}

final class ArenaBlockItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  CatalogAsyncPreviewProviding, CatalogGridPreviewProviding, @unchecked Sendable
{
  let block: ArenaBlock
  let capturedAtDate: Date

  var textValue: String { block.openURL.absoluteString }

  init(block: ArenaBlock, connectionID: String) {
    self.block = block
    capturedAtDate = block.updatedAt ?? .distantPast
    super.init(
      id: "arena.block.\(connectionID).\(block.id)",
      title: block.title,
      path: block.openURL.absoluteString
    )
    typeID = .arenaBlock
  }

  override var detail: String? {
    let description = block.description?.trimmingCharacters(in: .whitespacesAndNewlines)
    return description?.isEmpty == false ? description : block.kind.displayName
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(block.kind.symbolName)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    guard let imageURL = block.imageURL else { return nil }
    return await ArenaImageLoader.shared.preview(for: imageURL, maxDimension: maxDimension)
  }
}

private actor ArenaImageLoader {
  static let shared = ArenaImageLoader()

  private let session = URLSession(configuration: .ephemeral)
  private var cache: [URL: Data?] = [:]

  func preview(for url: URL, maxDimension: CGFloat) async -> CatalogItemPreview? {
    let data: Data?
    if let cached = cache[url] {
      data = cached
    } else {
      data = await fetch(url)
      cache[url] = data
    }

    guard let data, let image = NSImage(data: data) else { return nil }
    return CatalogItemPreview(image: scaled(image, maxDimension: maxDimension))
  }

  private func fetch(_ url: URL) async -> Data? {
    var request = URLRequest(url: url)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    guard
      let (data, response) = try? await session.data(for: request),
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      NSImage(data: data) != nil
    else { return nil }
    return data
  }

  private func scaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
    let dominant = max(image.size.width, image.size.height)
    guard dominant > maxDimension, dominant > 0 else { return image }
    let scale = maxDimension / dominant
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let result = NSImage(size: size)
    result.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size))
    result.unlockFocus()
    return result
  }
}

enum ArenaResolutionError: LocalizedError {
  case unsupportedItem
  case invalidDownload

  var errorDescription: String? {
    switch self {
    case .unsupportedItem: "This Are.na item cannot be resolved."
    case .invalidDownload: "Are.na returned an invalid download."
    }
  }
}

actor ArenaBlockResolver {
  static let shared = ArenaBlockResolver()

  private let session = URLSession(configuration: .ephemeral)
  private let fileManager = FileManager.default

  func resolve(_ block: ArenaBlock) async throws -> CatalogItem {
    switch block.resolution {
    case .text(let text):
      return TextSnippetItem(text: text)
    case .url(let url):
      return URLItem(urlString: url.absoluteString)
    case .download(let url, let filename):
      let localURL = try await download(
        url, blockID: block.id, preferredFilename: filename)
      return FileSystemEntity(
        displayName: localURL.lastPathComponent,
        url: localURL,
        kind: .file,
        capturedAtDate: block.updatedAt ?? .distantPast
      )
    }
  }

  private func download(_ url: URL, blockID: Int, preferredFilename: String?) async throws -> URL {
    let (temporaryURL, response) = try await session.download(from: url)
    if let response = response as? HTTPURLResponse,
      !(200..<300).contains(response.statusCode)
    {
      throw ArenaResolutionError.invalidDownload
    }

    let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tuna/Resolved/Are.na", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let rawFilename = preferredFilename ?? response.suggestedFilename ?? url.lastPathComponent
    let filename = safeFilename(rawFilename, fallback: "arena-block-\(blockID)")
    let destination = directory.appendingPathComponent("\(blockID)-\(filename)")
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: temporaryURL, to: destination)
    return destination
  }

  private func safeFilename(_ value: String, fallback: String) -> String {
    let filename = value
      .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let filename, !filename.isEmpty, filename != ".", filename != ".." else {
      return fallback
    }
    return filename
  }
}

extension TypeID {
  static let arenaChannel = TypeID("com.tuna.type.arena-channel")
  static let arenaBlock = TypeID("com.tuna.type.arena-block")
}
