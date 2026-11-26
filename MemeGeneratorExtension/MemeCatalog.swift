import AppKit
import Foundation
import TunaKit

private enum MemeCatalogMode {
  case source
  case browse
}

/// What the catalogs read and write. Tests inject stubs; Tuna uses `.live`.
struct MemeCatalogDependencies: Sendable {
  let library: MemeTemplateLibrary
  let thumbnails: MemeThumbnailCache
  let favorites: MemeFavorites
  let providers: @Sendable () -> [MemeProvider]

  static let live = MemeCatalogDependencies(
    library: .live, thumbnails: .live, favorites: .live,
    providers: { MemeSettings.enabledProviders })
}

/// Every template, from the cache only. Not in global search by default; favorites are listed first.
public final class MemeTemplatesCatalog: MemeTemplatesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .source)
  }

  init(definition: CatalogDefinition, dependencies: MemeCatalogDependencies) {
    super.init(definition: definition, mode: .source, dependencies: dependencies)
  }
}

/// "Make Meme" browse root: the only global entry, showing a thumbnail grid, favorites first.
public final class MemeTemplatesBrowseCatalog: MemeTemplatesCatalogBase {
  public required init(definition: CatalogDefinition) {
    super.init(definition: definition, mode: .browse)
  }

  init(definition: CatalogDefinition, dependencies: MemeCatalogDependencies) {
    super.init(definition: definition, mode: .browse, dependencies: dependencies)
  }
}

@MainActor
public class MemeTemplatesCatalogBase: NSObject, Catalog, RescanSchedulingCatalog {
  public let identifier: String
  public let name: String
  public var availabilityStatus: CatalogAvailabilityStatus = .normal
  public var rescanHandler: (() -> Void)?

  private let mode: MemeCatalogMode
  private let dependencies: MemeCatalogDependencies
  private let itemsStore = LockedValue<[CatalogItem]>([])
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
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
    loadChildren: { [dependencies] in
      await Self.loadBrowseChildren(dependencies)
    }
  )

  /// First use: the only place templates are fetched and thumbnails prefetched (never at launch).
  nonisolated static func loadBrowseChildren(_ dependencies: MemeCatalogDependencies) async
    -> [CatalogItem]
  {
    let result = await dependencies.library.load(providers: dependencies.providers())
    if result.failures.isEmpty {
      dependencies.thumbnails.prune(keeping: result.templates)
    }
    dependencies.thumbnails.prefetch(result.templates)
    return MemeCatalogSupport.items(for: result, favorites: dependencies.favorites)
  }

  public var objects: [CatalogItem] {
    switch mode {
    case .source: itemsStore.readValue { $0 }
    case .browse: [browseItem]
    }
  }

  fileprivate init(
    definition: CatalogDefinition, mode: MemeCatalogMode,
    dependencies: MemeCatalogDependencies = .live
  ) {
    identifier = definition.identifier
    name = definition.name
    self.mode = mode
    self.dependencies = dependencies
    super.init()
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .memeTemplatesDidChange, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.mode == .browse { self.browseItem.reset() }
          self.rescanHandler?()
        }
      })
    if mode == .source {
      // A first browse filled the cache: pick it up (the scan itself never fetches).
      observers.append(
        center.addObserver(forName: .memeTemplateCacheDidUpdate, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.rescanHandler?() }
        })
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    // Disabling Make Meme drops this catalog; stop any thumbnail downloads it started.
    if mode == .browse { dependencies.thumbnails.cancelPrefetch() }
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
      // Launch scan: cached templates only. No network, no refresh, no thumbnail prefetch (P4).
      let result = dependencies.library.cachedTemplates(providers: dependencies.providers())
      itemsStore.value = dependencies.favorites.ordered(result.templates).map(MemeTemplateItem.init)
      availabilityStatus = .normal
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
    let templates: [CatalogItem] = favorites.ordered(result.templates).map(MemeTemplateItem.init)
    guard !result.failures.isEmpty else { return templates }
    // Partial results stay visible: say which provider is missing (P10).
    let names = result.failures.keys.map(\.displayName).sorted().joined(separator: ", ")
    let messages = result.failures.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
    return [
      CatalogMessageItem(
        title: "\(names) templates unavailable", message: messages.joined(separator: " "),
        symbolName: "exclamationmark.triangle", tintColor: .systemOrange)
    ] + templates
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
