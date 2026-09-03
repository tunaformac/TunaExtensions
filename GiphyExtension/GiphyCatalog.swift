import AppKit
import Foundation
import TunaKit

public final class GiphyCatalog: Catalog, CatalogViewProviding,
  CatalogGridConfigurationProviding, StartupScanningCatalog, RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public let resultsViewStyle = CatalogResultsView.grid
  public let gridConfiguration = GiphyCatalogSupport.gridConfiguration

  private lazy var rootItem = GiphyCatalogRootItem(
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    }
  )

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async {
    rootItem.reset()
    reportScanFinished()
  }

  public func releaseRetainedState() {
    rootItem.reset()
  }
}

enum GiphyCatalogSupport {
  static let gridConfiguration = CatalogGridConfiguration(
    columns: 4,
    minimumCellSize: 88,
    maximumCellSize: 140,
    spacing: 4,
    padding: 4,
    cellPadding: 8
  )

  static func loadingItem() -> CatalogLoadingItem {
    CatalogLoadingItem(title: "Loading GIPHY", message: "Fetching GIFs from GIPHY.")
  }

  static func errorItem(_ error: Error) -> CatalogMessageItem {
    CatalogMessageItem(
      title: "GIPHY request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func emptyItem(query: String?) -> CatalogMessageItem {
    CatalogMessageItem(
      title: query == nil ? "No trending GIFs" : "No GIFs found",
      message: query.map { "No GIPHY results matched “\($0)”." }
        ?? "GIPHY did not return any trending GIFs.",
      symbolName: "photo.stack",
      tintColor: .secondaryLabelColor
    )
  }
}

final class GiphyCatalogRootItem: CatalogEntity, CatalogHierarchyNode,
  ScopedCatalogSearchPagingProviding, @unchecked Sendable
{
  private let deferredItem: DeferredBrowseCatalogItem

  var scopedSearchConfiguration: ScopedSearchConfiguration {
    ScopedSearchConfiguration(debounce: .milliseconds(500), searchOnChange: true)
  }

  init(didLoad: (@Sendable () -> Void)? = nil) {
    deferredItem = DeferredBrowseCatalogItem(
      title: "GIPHY",
      id: "giphy.trending",
      detail: "Trending GIFs · Powered by GIPHY",
      catalogIcon: .init(symbolName: "photo.stack", color: .pink),
      loadingItemProvider: { GiphyCatalogSupport.loadingItem() },
      errorItemProvider: { GiphyCatalogSupport.errorItem($0) },
      didLoad: didLoad,
      loadChildren: {
        let page = try await GiphyAPIClient.live.page(query: nil, page: 1)
        return page.gifs.isEmpty
          ? [GiphyCatalogSupport.emptyItem(query: nil)]
          : page.gifs.map(GiphyGIFItem.init)
      }
    )
    super.init(id: "giphy", title: "GIPHY", path: nil)
    typeID = .dynamicSearchCatalogEntry
  }

  override var detail: String? { "Search GIFs · Powered by GIPHY" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: "photo.stack", color: .pink, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    deferredItem.hierarchyChildren()
  }

  func scopedSearchPage(query: String, page: Int) async throws -> ScopedSearchPage {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveQuery = trimmedQuery.isEmpty ? nil : query
    let result = try await GiphyAPIClient.live.page(query: effectiveQuery, page: page)
    let items: [CatalogItem] = if result.gifs.isEmpty && page == 1 {
      [GiphyCatalogSupport.emptyItem(query: effectiveQuery)]
    } else {
      result.gifs.map(GiphyGIFItem.init)
    }
    return ScopedSearchPage(items: items, hasMore: result.hasMore)
  }

  func reset() {
    deferredItem.reset()
  }
}

final class GiphyGIFItem: CatalogEntity, TextValueProviding, CopyRepresentationProviding,
  PasteboardDataProviding, CatalogAsyncPreviewProviding, CatalogGridPreviewProviding,
  CatalogQuickLookProviding, @unchecked Sendable
{
  let gif: GiphyGIF

  var textValue: String { gif.originalURL.absoluteString }
  var copyRepresentation: String? { gif.originalURL.absoluteString }
  var pasteboardDataRepresentation: PasteboardDataRepresentation? {
    PasteboardDataRepresentation(
      typeRawValue: NSPasteboard.PasteboardType.html.rawValue,
      data: Data(htmlRepresentation.utf8)
    )
  }

  init(gif: GiphyGIF) {
    self.gif = gif
    super.init(id: "giphy.gif.\(gif.id)", title: gif.displayTitle, path: gif.pageURL.absoluteString)
    typeID = .giphyGIF
  }

  override var detail: String? {
    [gif.username.map { "@\($0)" }, "Powered by GIPHY"]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  override var searchKeys: [String] {
    [gif.displayTitle, gif.altText, gif.username].compactMap { $0 }
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("photo")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    await GiphyImageLoader.preview(from: gif.previewURL)
  }

  func quickLookURLs() async throws -> [URL] {
    [try await GiphyResolver.live.resolve(gif).url]
  }

  private var htmlRepresentation: String {
    let alt = Self.escapeHTML(gif.altText ?? gif.displayTitle)
    return #"<img src="\#(gif.originalURL.absoluteString)" alt="\#(alt)">"#
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

private enum GiphyImageLoader {
  static func preview(from url: URL) async -> CatalogItemPreview? {
    var request = URLRequest(url: url)
    request.setValue("image/gif,image/*;q=0.8", forHTTPHeaderField: "Accept")
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      response.mimeType?.hasPrefix("image/") != false
    else { return nil }
    return CatalogItemPreview(animatedImageData: data)
  }
}
