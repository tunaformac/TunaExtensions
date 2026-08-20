import AppKit
import Foundation
import TunaKit
import UniformTypeIdentifiers

enum MyMindCatalogSupport {
  static let gridConfiguration = CatalogGridConfiguration(
    columns: 4,
    minimumCellSize: 88,
    maximumCellSize: 140,
    spacing: 4,
    padding: 4,
    cellPadding: 8
  )

  static func authRequiredItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Set up mymind",
      message: "Add a Key ID and Private Key in extension settings.",
      symbolName: "brain",
      tintColor: .systemOrange
    )
  }

  static func loadingItem(_ subject: String = "your mind") -> CatalogLoadingItem {
    CatalogLoadingItem(title: "Loading \(subject)", message: "Fetching content from mymind.")
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
      title: "mymind request failed",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func safeFilename(_ value: String?, fallback: String) -> String {
    let filename = value?
      .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
      .last?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let filename, !filename.isEmpty, filename != ".", filename != ".." else {
      return fallback
    }
    return filename
  }

  static func detail(for object: MyMindObject) -> String {
    var parts = [object.kind.displayName]
    if let bumped = object.bumped {
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      parts.append("Bumped \(formatter.localizedString(for: bumped, relativeTo: Date()))")
    }
    return parts.joined(separator: " · ")
  }
}

final class MyMindCatalogRootItem: CatalogEntity, CatalogHierarchyNode,
  ScopedCatalogSearchPagingProviding, @unchecked Sendable
{
  private static let dynamicSearchType = TypeID("com.tuna.type.dynamic-search-catalog-entry")

  private let catalogIcon: BrowseCatalogItem.CatalogIcon
  private let deferredItem: DeferredBrowseCatalogItem
  private let searchPageHandler: @Sendable (String, Int) async throws -> ScopedSearchPage

  var scopedSearchConfiguration: ScopedSearchConfiguration {
    ScopedSearchConfiguration(debounce: .milliseconds(350), searchOnChange: true)
  }

  init(
    title: String,
    id: String,
    detail: String,
    catalogIcon: BrowseCatalogItem.CatalogIcon,
    didLoad: (@Sendable () -> Void)? = nil,
    loadChildren: @escaping @Sendable () async throws -> [CatalogItem],
    searchPageHandler: @escaping @Sendable (String, Int) async throws -> ScopedSearchPage
  ) {
    self.catalogIcon = catalogIcon
    self.searchPageHandler = searchPageHandler
    self.deferredItem = DeferredBrowseCatalogItem(
      title: title,
      id: id,
      detail: detail,
      catalogIcon: catalogIcon,
      loadingItemProvider: { MyMindCatalogSupport.loadingItem() },
      errorItemProvider: { MyMindCatalogSupport.errorItem($0) },
      didLoad: didLoad,
      loadChildren: loadChildren
    )
    super.init(id: id, title: title, path: nil)
    typeID = Self.dynamicSearchType
  }

  override var detail: String? { deferredItem.detail }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(
      symbolName: catalogIcon.symbolName,
      color: catalogIcon.color,
      maxDimension: maxDimension
    )
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    deferredItem.hierarchyChildren()
  }

  func scopedSearchPage(query: String, page: Int) async throws -> ScopedSearchPage {
    try await searchPageHandler(query, page)
  }

  func reset() {
    deferredItem.reset()
  }
}

final class MyMindSpaceItem: CatalogEntity, CatalogHierarchyNode, CatalogHierarchyViewProviding,
  ScopedCatalogSearchProviding, TimestampedCatalogItem, @unchecked Sendable
{
  let space: MyMindSpace
  let credentials: MyMindCredentials
  let capturedAtDate: Date

  private let catalogIdentifier: String
  private let childrenStore = LockedValue<[CatalogItem]>([])
  private let loadState = DeferredCatalogLoadState()
  private let loadTask = LockedValue<Task<Void, Never>?>(nil)

  var childResultsPresentation: CatalogResultsPresentation {
    .grid(MyMindCatalogSupport.gridConfiguration)
  }

  var scopedSearchConfiguration: ScopedSearchConfiguration {
    ScopedSearchConfiguration(debounce: .milliseconds(300), searchOnChange: true)
  }

  init(space: MyMindSpace, credentials: MyMindCredentials, catalogIdentifier: String) {
    self.space = space
    self.credentials = credentials
    self.catalogIdentifier = catalogIdentifier
    capturedAtDate = space.created ?? .distantPast
    super.init(id: "mymind.space.\(space.id)", title: space.name, path: nil)
    typeID = .myMindSpace
  }

  override var detail: String? { "mymind Space" }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("square.grid.2x2")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    loadState.requestLoadIfNeeded { [weak self] in self?.loadObjects() }
    let children = childrenStore.readValue { $0 }
    if !children.isEmpty || loadState.didCompleteLoad { return children }
    return [MyMindCatalogSupport.loadingItem(space.name)]
  }

  func scopedSearch(query: String) async throws -> [CatalogItem] {
    let objects = try await MyMindAPIClient(credentials: credentials)
      .listObjects(query: query, spaceID: space.id, limit: 40)
    return objects.isEmpty
      ? [MyMindCatalogSupport.emptyItem(
          title: "No matches",
          message: "No objects in this Space matched your search."
        )]
      : objects.map { MyMindObjectItem(object: $0, credentials: credentials) }
  }

  private func loadObjects() {
    loadTask.withValue { task in
      guard task == nil else { return }
      let credentials = credentials
      let space = space
      task = Task { [weak self] in
        guard let self else { return }
        do {
          let objects = try await MyMindAPIClient(credentials: credentials)
            .listObjects(spaceID: space.id, limit: 40)
          childrenStore.value = objects.isEmpty
            ? [MyMindCatalogSupport.emptyItem(
                title: "Empty Space",
                message: "This mymind Space does not contain any objects."
              )]
            : objects.map { MyMindObjectItem(object: $0, credentials: credentials) }
        } catch {
          childrenStore.value = [MyMindCatalogSupport.errorItem(error)]
        }
        loadState.markLoadCompleted()
        loadTask.value = nil
        NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
      }
    }
  }
}

final class MyMindObjectItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  CatalogAsyncPreviewProviding, CatalogGridPreviewProviding, CatalogQuickLookProviding,
  @unchecked Sendable
{
  let object: MyMindObject
  let credentials: MyMindCredentials
  let capturedAtDate: Date

  var textValue: String {
    object.sourceURL?.absoluteString ?? object.content?.body ?? title
  }

  init(object: MyMindObject, credentials: MyMindCredentials) {
    self.object = object
    self.credentials = credentials
    capturedAtDate = object.recencyDate
    super.init(
      id: "mymind.object.\(object.id)",
      title: object.displayTitle,
      path: nil
    )
    typeID = .myMindObject
  }

  override var detail: String? { MyMindCatalogSupport.detail(for: object) }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(object.kind.symbolName)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    switch object.kind {
    case .article, .image, .video, .document:
      break
    case .note, .file, .object:
      return nil
    }
    return await MyMindImageLoader.shared.preview(
      object: object,
      credentials: credentials,
      maxDimension: maxDimension
    )
  }

  func quickLookURLs() async throws -> [URL] {
    [try await MyMindObjectResolver.shared.quickLookURL(for: self)]
  }
}

private actor MyMindImageLoader {
  static let shared = MyMindImageLoader()

  private static let cacheLimit = 128
  private var cache: [String: Data] = [:]

  func preview(
    object: MyMindObject,
    credentials: MyMindCredentials,
    maxDimension: CGFloat
  ) async -> CatalogItemPreview? {
    let size = max(32, min(1_024, Int(maxDimension.rounded(.up))))
    let key = "\(object.cacheKey).\(size)"
    if let cached = cache[key] {
      guard let image = NSImage(data: cached) else { return nil }
      return CatalogItemPreview(image: image)
    }
    let data = try? await MyMindAPIClient(credentials: credentials)
      .thumbnail(objectID: object.id, size: size)
    if let data {
      if cache.count >= Self.cacheLimit, let oldestKey = cache.keys.first {
        cache.removeValue(forKey: oldestKey)
      }
      cache[key] = data
    }
    guard let data, let image = NSImage(data: data) else { return nil }
    return CatalogItemPreview(image: image)
  }
}

enum MyMindResolutionError: LocalizedError {
  case unsupportedObject
  case invalidDownload

  var errorDescription: String? {
    switch self {
    case .unsupportedObject: "This mymind object cannot be resolved."
    case .invalidDownload: "mymind returned an invalid download."
    }
  }
}

actor MyMindObjectResolver {
  static let shared = MyMindObjectResolver()

  private let fileManager = FileManager.default

  func resolve(_ item: MyMindObjectItem) async throws -> CatalogItem {
    let object = item.object
    if object.kind == .image, object.blob == nil {
      let url = try await writeThumbnailPreview(object, credentials: item.credentials)
      return fileEntity(for: object, filename: "\(object.displayTitle).png", url: url)
    }
    if object.blob != nil {
      return try await resolveBlob(object, credentials: item.credentials)
    }
    if let sourceURL = object.sourceURL {
      return URLItem(urlString: sourceURL.absoluteString)
    }
    if let body = object.content?.body, !body.isEmpty {
      return TextSnippetItem(text: body)
    }

    let content = try await MyMindAPIClient(credentials: item.credentials).content(objectID: object.id)
    guard !content.isEmpty else { throw MyMindResolutionError.unsupportedObject }
    return TextSnippetItem(text: content)
  }

  func quickLookURL(for item: MyMindObjectItem) async throws -> URL {
    let object = item.object
    if object.kind == .image {
      if object.blob == nil {
        return try await writeThumbnailPreview(object, credentials: item.credentials)
      }
      return try await resolveBlob(object, credentials: item.credentials).url
    }
    if object.blob != nil {
      return try await resolveBlob(object, credentials: item.credentials).url
    }
    if let body = object.content?.body, !body.isEmpty {
      return try writeTextPreview(body, objectID: object.id)
    }
    if let sourceURL = object.sourceURL {
      if let thumbnailURL = try? await writeThumbnailPreview(object, credentials: item.credentials) {
        return thumbnailURL
      }
      return try writeWebLocation(sourceURL, objectID: object.id)
    }

    let content = try await MyMindAPIClient(credentials: item.credentials).content(objectID: object.id)
    guard !content.isEmpty else { throw MyMindResolutionError.unsupportedObject }
    return try writeTextPreview(content, objectID: object.id)
  }

  private func resolveBlob(_ object: MyMindObject, credentials: MyMindCredentials) async throws
    -> FileSystemEntity
  {
    let directory = try previewDirectory()
    let filename = blobFilename(for: object)
    let destination = directory.appendingPathComponent("\(object.cacheKey)-\(filename)")
    if fileManager.fileExists(atPath: destination.path) {
      return fileEntity(for: object, filename: filename, url: destination)
    }

    let (temporaryURL, _) = try await MyMindAPIClient(credentials: credentials)
      .downloadBlob(objectID: object.id)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: temporaryURL, to: destination)
    return fileEntity(for: object, filename: filename, url: destination)
  }

  private func fileEntity(for object: MyMindObject, filename: String, url: URL) -> FileSystemEntity {
    FileSystemEntity(
      displayName: filename,
      url: url,
      kind: .file,
      capturedAtDate: object.recencyDate
    )
  }

  private func blobFilename(for object: MyMindObject) -> String {
    let extensionName = object.blob.flatMap { UTType(mimeType: $0.type)?.preferredFilenameExtension }
    let fallback = extensionName.map { "mymind-\(object.id).\($0)" } ?? "mymind-\(object.id)"
    return MyMindCatalogSupport.safeFilename(object.blob?.name, fallback: fallback)
  }

  private func writeTextPreview(_ text: String, objectID: String) throws -> URL {
    let destination = try previewDirectory()
      .appendingPathComponent("\(objectID)-preview.md")
    try Data(text.utf8).write(to: destination, options: .atomic)
    return destination
  }

  private func writeThumbnailPreview(_ object: MyMindObject, credentials: MyMindCredentials) async throws
    -> URL
  {
    let destination = try previewDirectory()
      .appendingPathComponent("\(object.cacheKey)-preview.png")
    if fileManager.fileExists(atPath: destination.path) { return destination }

    let data = try await MyMindAPIClient(credentials: credentials)
      .thumbnail(objectID: object.id, size: 1_024)
    guard
      let image = NSImage(data: data),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw MyMindResolutionError.invalidDownload }
    try png.write(to: destination, options: .atomic)
    return destination
  }

  private func writeWebLocation(_ url: URL, objectID: String) throws -> URL {
    let destination = try previewDirectory()
      .appendingPathComponent("\(objectID)-preview.webloc")
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["URL": url.absoluteString],
      format: .xml,
      options: 0
    )
    try data.write(to: destination, options: .atomic)
    return destination
  }

  private func previewDirectory() throws -> URL {
    let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Tuna/Resolved/mymind", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
