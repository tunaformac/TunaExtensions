import AppKit
import Foundation
import TunaKit
import UniformTypeIdentifiers

/// "Cloud Shared": a browse root plus one item per destination. Destinations are also the
/// targets of "Cloud Share to…". Objects load only when a destination is browsed.
public final class CloudShareCatalog: Catalog, RescanSchedulingCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?

  private let destinationsStore = LockedValue<[CatalogItem]>([])

  private lazy var rootItem = BrowseCatalogItem(
    title: "Cloud Shared",
    id: "cloudshare.root",
    detail: "Files in your Cloud Share storage",
    catalogIcon: .init(symbolName: "icloud.and.arrow.up", color: .blue),
    childrenProvider: { [weak self] in self?.browseChildren() ?? [] }
  )

  public var objects: [CatalogItem] {
    [rootItem] + destinationsStore.readValue { $0.filter { $0 is CloudShareDestinationItem } }
  }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  /// Reads destinations from settings only; no network and no Keychain access. Listings are
  /// dropped so the next browse shows the bucket as it is now, with any edited settings.
  public func scan() async {
    let catalogIdentifier = identifier
    CloudShareListingStore.shared.reset()
    destinationsStore.value = CloudShareSettings.destinations(for: CloudShareCatalog.self).map {
      switch $0 {
      case .success(let destination):
        CloudShareDestinationItem(destination: destination, catalogIdentifier: catalogIdentifier)
      case .failure(let error):
        CloudShareCatalogSupport.errorItem(error, title: "Destination needs setup")
      }
    }
    NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
  }

  public func releaseRetainedState() {
    destinationsStore.value = []
    CloudShareListingStore.shared.reset()
  }

  private func browseChildren() -> [CatalogItem] {
    let items = destinationsStore.readValue { $0 }
    if items.isEmpty {
      return [CloudShareCatalogSupport.noDestinationsItem()]
    }
    // With a single destination, skip straight to its files.
    if items.count == 1, let destination = items.first as? CloudShareDestinationItem {
      return destination.hierarchyChildren()
    }
    return items
  }
}

enum CloudShareCatalogSupport {
  static func noDestinationsItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Add a destination",
      message: "Add an S3 destination in Tuna Settings → Extensions → Cloud Share.",
      symbolName: "icloud.and.arrow.up",
      tintColor: .systemOrange
    )
  }

  static func errorItem(_ error: Error, title: String = "Cloud Share request failed")
    -> CatalogMessageItem
  {
    errorItem(error.localizedDescription, title: title)
  }

  static func errorItem(_ message: String, title: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: title,
      message: message,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  static func loadingItem(_ name: String) -> CatalogLoadingItem {
    CatalogLoadingItem(title: "Loading \(name)", message: "Listing files in the bucket.")
  }

  static func emptyItem() -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Nothing shared yet",
      message: "Files you Cloud Share appear here.",
      symbolName: "tray",
      tintColor: .secondaryLabelColor
    )
  }

  static func truncatedItem(count: Int) -> CatalogMessageItem {
    CatalogMessageItem(
      title: "Showing \(count) files",
      message: "The bucket has more files than Tuna lists.",
      symbolName: "ellipsis.circle",
      tintColor: .secondaryLabelColor
    )
  }
}

/// Bucket listings, shared by every item for a destination so uploads and deletes can
/// invalidate them regardless of which catalog snapshot the user is browsing.
///
/// A listing belongs to the destination settings it was made with: editing a destination lists
/// again. Rescans drop every listing. Browsing a listing older than `refreshInterval` keeps
/// showing it while the bucket is listed again, so files added elsewhere appear; a failure is
/// retried when browsed after `retryInterval`. A load that finishes after being superseded is
/// ignored.
final class CloudShareListingStore: @unchecked Sendable {
  static let shared = CloudShareListingStore()

  enum State: Sendable {
    case loading
    case loaded([CloudShareObject], truncated: Bool)
    case failed(String)
  }

  typealias Loader = @Sendable (CloudShareDestination) async throws -> (
    objects: [CloudShareObject], truncated: Bool
  )

  private struct Entry {
    let listingKey: String
    var state: State
    var finishedAt: Date?
    /// The load in flight, if any; only its result is kept.
    var load: (token: UUID, task: Task<Void, Never>)?
  }

  /// Waits between retries of a failed listing, so re-showing the failure doesn't relist.
  static let retryInterval: TimeInterval = 5
  static let refreshInterval: TimeInterval = 30

  private let entries = LockedValue<[String: Entry]>([:])
  private let loader: Loader
  private let now: @Sendable () -> Date

  init(
    loader: @escaping Loader = { try await CloudShareS3Client(destination: $0).listRecentObjects() },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.loader = loader
    self.now = now
  }

  func state(for destination: CloudShareDestination, catalogIdentifier: String) -> State {
    let date = now()
    return entries.withValue { entries in
      let id = destination.id
      if let entry = entries[id], entry.listingKey == destination.listingKey {
        guard entry.load == nil, let finishedAt = entry.finishedAt else { return entry.state }
        let age = date.timeIntervalSince(finishedAt)
        switch entry.state {
        case .loaded where age >= Self.refreshInterval:
          entries[id]?.load = startLoad(destination, catalogIdentifier: catalogIdentifier)
          return entry.state
        case .failed where age >= Self.retryInterval:
          break
        default:
          return entry.state
        }
      }
      entries[id]?.load?.task.cancel()
      entries[id] = Entry(
        listingKey: destination.listingKey, state: .loading,
        load: startLoad(destination, catalogIdentifier: catalogIdentifier))
      return .loading
    }
  }

  func invalidate(destinationID: String) {
    entries.withValue { $0.removeValue(forKey: destinationID)?.load?.task.cancel() }
  }

  func reset() {
    entries.withValue { entries in
      entries.values.forEach { $0.load?.task.cancel() }
      entries = [:]
    }
  }

  /// Called with the entries locked; the task only touches them once it finishes.
  private func startLoad(_ destination: CloudShareDestination, catalogIdentifier: String)
    -> (token: UUID, task: Task<Void, Never>)
  {
    let token = UUID()
    let task = Task { [weak self, loader] in
      let state: State
      do {
        let result = try await loader(destination)
        state = .loaded(result.objects, truncated: result.truncated)
      } catch {
        state = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      let finishedAt = self.now()
      let current = self.entries.withValue { entries -> Bool in
        guard entries[destination.id]?.load?.token == token else { return false }
        entries[destination.id]?.state = state
        entries[destination.id]?.finishedAt = finishedAt
        entries[destination.id]?.load = nil
        return true
      }
      if current {
        NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
      }
    }
    return (token, task)
  }
}

final class CloudShareDestinationItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  let destination: CloudShareDestination
  private let catalogIdentifier: String

  init(destination: CloudShareDestination, catalogIdentifier: String) {
    self.destination = destination
    self.catalogIdentifier = catalogIdentifier
    super.init(
      id: "cloudshare.destination.\(destination.id)",
      title: destination.name,
      path: nil
    )
    typeID = .cloudShareDestination
  }

  override var detail: String? {
    destination.publicBaseURL?.host ?? destination.bucket
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("externaldrive.badge.icloud")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    switch CloudShareListingStore.shared.state(
      for: destination, catalogIdentifier: catalogIdentifier)
    {
    case .loading:
      return [CloudShareCatalogSupport.loadingItem(destination.name)]
    case .failed(let message):
      return [
        CatalogMessageItem(
          title: "Couldn't list \(destination.name)",
          message: message,
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange
        )
      ]
    case .loaded(let objects, let truncated):
      guard !objects.isEmpty else { return [CloudShareCatalogSupport.emptyItem()] }
      let items: [CatalogItem] = objects.map {
        CloudShareObjectItem(object: $0, destination: destination)
      }
      return truncated ? items + [CloudShareCatalogSupport.truncatedItem(count: objects.count)] : items
    }
  }
}

final class CloudShareObjectItem: CatalogEntity, TextValueProviding, TimestampedCatalogItem,
  @unchecked Sendable
{
  let object: CloudShareObject
  let destination: CloudShareDestination
  let publicURL: URL
  let capturedAtDate: Date

  var textValue: String { publicURL.absoluteString }

  init(object: CloudShareObject, destination: CloudShareDestination) {
    self.object = object
    self.destination = destination
    publicURL = destination.publicURL(forKey: object.key)
    capturedAtDate = object.lastModified
    super.init(
      id: "cloudshare.object.\(destination.id).\(object.key)",
      title: (object.key as NSString).lastPathComponent,
      path: publicURL.absoluteString
    )
    typeID = .cloudShareObject
  }

  override var detail: String? {
    let folder = (object.key as NSString).deletingLastPathComponent
    let size = ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
    return [folder.isEmpty ? nil : folder, size].compactMap { $0 }.joined(separator: " · ")
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    let pathExtension = (object.key as NSString).pathExtension
    let type = UTType(filenameExtension: pathExtension) ?? .data
    return CatalogItemPreview(image: NSWorkspace.shared.icon(for: type))
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}
