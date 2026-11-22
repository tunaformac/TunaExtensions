import AppKit
import Foundation
import TunaKit

private enum MemeCatalogMode {
  case source
  case browse
}

/// Every template, indexed for global search. Favorites are listed first.
public final class MemeTemplatesCatalog: MemeTemplatesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .source)
  }
}

/// "Make Meme" browse root: the only global entry, showing a thumbnail grid, favorites first.
public final class MemeTemplatesBrowseCatalog: MemeTemplatesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .browse)
  }
}

@MainActor
public class MemeTemplatesCatalogBase: NSObject, Catalog, RescanSchedulingCatalog {
  public let identifier: String
  public let name: String
  public var availabilityStatus: CatalogAvailabilityStatus = .normal
  public var rescanHandler: (() -> Void)?

  private let mode: MemeCatalogMode
  private let itemsStore = LockedValue<[CatalogItem]>([])
  private var observer: NSObjectProtocol?
  private lazy var browseItem = DeferredBrowseCatalogItem(
    title: "Make Meme",
    id: "memes.templates",
    detail: "Pick a meme template",
    catalogIcon: .init(symbolName: "face.smiling", color: .yellow),
    childResultsPresentation: .grid(MemeCatalogSupport.gridConfiguration),
    loadingItemProvider: { CatalogLoadingItem(title: "Loading Memes", message: "Fetching meme templates.") },
    errorItemProvider: { MemeCatalogSupport.errorItem($0.localizedDescription) },
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: {
      let result = await MemeTemplateLibrary.live.load(providers: MemeSettings.enabledProviders)
      return MemeCatalogSupport.items(for: result, favorites: .live)
    }
  )

  public var objects: [CatalogItem] {
    switch mode {
    case .source: itemsStore.readValue { $0 }
    case .browse: [browseItem]
    }
  }

  fileprivate init(definition: CatalogDefinition, mode: MemeCatalogMode) {
    identifier = definition.identifier
    name = definition.name
    self.mode = mode
    super.init()
    observer = NotificationCenter.default.addObserver(
      forName: .memeTemplatesDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.mode == .browse { self.browseItem.reset() }
        self.rescanHandler?()
      }
    }
  }

  public required init(definition: CatalogDefinition) {
    fatalError("Use a concrete meme templates catalog type.")
  }

  public func scan() async {
    switch mode {
    case .browse:
      browseItem.reset()
      availabilityStatus = .normal
    case .source:
      let result = await MemeTemplateLibrary.live.load(providers: MemeSettings.enabledProviders)
      itemsStore.value = MemeFavorites.live.ordered(result.templates).map(MemeTemplateItem.init)
      availabilityStatus = MemeCatalogSupport.status(for: result)
      MemeThumbnailCache.live.prefetch(result.templates)
    }
    reportScanFinished()
  }
}

enum MemeCatalogSupport {
  static let gridConfiguration = CatalogGridConfiguration(
    columns: 4, minimumCellSize: 88, maximumCellSize: 160, spacing: 4, padding: 4, cellPadding: 6)

  static func items(for result: MemeTemplateLibrary.LoadResult, favorites: MemeFavorites)
    -> [CatalogItem]
  {
    if result.templates.isEmpty {
      return [errorItem(result.failures.values.first ?? "No meme templates are available.")]
    }
    return favorites.ordered(result.templates).map(MemeTemplateItem.init)
  }

  static func status(for result: MemeTemplateLibrary.LoadResult) -> CatalogAvailabilityStatus {
    if result.templates.isEmpty, !result.failures.isEmpty {
      return .disabled("Meme templates could not be loaded")
    }
    if !result.failures.isEmpty {
      let names = result.failures.keys.map(\.displayName).sorted().joined(separator: ", ")
      return .degraded("\(names) templates could not be loaded")
    }
    return .normal
  }

  static func errorItem(_ message: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Meme templates unavailable", message: message,
      symbolName: "exclamationmark.triangle", tintColor: .systemOrange)
  }
}

final class MemeTemplateItem: CatalogEntity, CatalogAsyncPreviewProviding,
  CatalogGridPreviewProviding, @unchecked Sendable
{
  let template: MemeTemplate

  init(_ template: MemeTemplate) {
    self.template = template
    // A path gives Tuna a stable preview identity, which grid thumbnails need.
    super.init(
      id: "memes.template.\(template.key)", title: template.name,
      path: template.thumbnailURL.absoluteString)
    typeID = .memeTemplate
  }

  var cachesAsyncPreview: Bool { true }

  var isFavorite: Bool { MemeFavorites.live.contains(template) }

  override var detail: String? {
    let lines = template.lineCount == 1 ? "1 line" : "\(template.lineCount) lines"
    return ([isFavorite ? "★ Favorite" : nil, template.provider.displayName, lines] as [String?])
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  override var searchKeys: [String] {
    [template.name, template.id] + template.keywords
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("face.smiling", tintColor: .systemYellow)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await MemeThumbnailCache.live.image(for: template).map { CatalogItemPreview(image: $0) }
  }
}

/// A generated meme saved to a temporary file, so Tuna's file actions (paste, share, Quick Look) work.
final class MemeImageItem: FileSystemEntity, PasteboardDataProviding, CatalogQuickLookProviding,
  @unchecked Sendable
{
  let meme: GeneratedMeme

  init(meme: GeneratedMeme, fileURL: URL) {
    self.meme = meme
    let caption = meme.lines.filter { !$0.isEmpty }.joined(separator: " / ")
    super.init(
      id: "memes.image.\(fileURL.lastPathComponent)",
      displayName: caption.isEmpty ? meme.template.name : caption,
      url: fileURL,
      kind: .file,
      capturedAtDate: .now
    )
    typeID = .memeImage
  }

  override var detail: String? {
    "\(meme.template.name) · \(meme.template.provider.displayName)"
  }

  var pasteboardDataRepresentation: PasteboardDataRepresentation? {
    PasteboardDataRepresentation(typeRawValue: Self.pasteboardType(for: meme).rawValue, data: meme.imageData)
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    if let image = NSImage(data: meme.imageData) { return CatalogItemPreview(image: image) }
    return .systemSymbol("photo")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func quickLookURLs() async throws -> [URL] { [url] }

  static func pasteboardType(for meme: GeneratedMeme) -> NSPasteboard.PasteboardType {
    switch meme.fileExtension {
    case "jpg": NSPasteboard.PasteboardType("public.jpeg")
    case "gif": NSPasteboard.PasteboardType("com.compuserve.gif")
    case "webp": NSPasteboard.PasteboardType("org.webmproject.webp")
    default: .png
    }
  }
}

enum MemeFileStore {
  static let directory = FileManager.default.temporaryDirectory
    .appending(path: "Tuna", directoryHint: .isDirectory)
    .appending(path: "Memes", directoryHint: .isDirectory)

  static func write(_ meme: GeneratedMeme, in directory: URL = directory) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = fileStem(meme.template.name)
    let suffix = UUID().uuidString.prefix(6).lowercased()
    let url = directory.appending(path: "\(stem)-\(suffix).\(meme.fileExtension)")
    try meme.imageData.write(to: url, options: .atomic)
    return url
  }

  static func fileStem(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: "-")
    return cleaned.isEmpty ? "meme" : String(cleaned.prefix(60))
  }
}
