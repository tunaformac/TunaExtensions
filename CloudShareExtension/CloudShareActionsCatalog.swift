import AppKit
import Foundation
import TunaKit
import UniformTypeIdentifiers

public final class CloudShareActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = [
    Self.shareAction(toShelf: false),
    Self.shareAction(toShelf: true),
    Self.shareToAction(toShelf: false),
    Self.shareToAction(toShelf: true),
    Self.deleteAction(),
    Self.testAction(),
  ]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  // MARK: - Share

  /// Inline variants wait for the upload and return the shared links as the result; the
  /// "to Shelf" copies upload in the background and leave the links on Shelf.
  private static func shareAction(toShelf: Bool) -> CatalogAction {
    let action = PredicateAwareAction(
      id: toShelf ? "share-to-shelf" : "share",
      title: toShelf ? "Cloud Share to Shelf" : "Cloud Share"
    ) { subject, _ in
      await share([subject], to: nil, toShelf: toShelf)
    }
    action.batchCallback = { subjects, _ in await share(subjects, to: nil, toShelf: toShelf) }
    action.systemSymbolName = "icloud.and.arrow.up"
    action.supportedSubjectTypes = [.file, .image]
    action.subjectPredicate = { CloudShareUpload.canShare($0) }
    if !toShelf { action.executionPolicy = .resultDriven }
    return action
  }

  private static func shareToAction(toShelf: Bool) -> CatalogAction {
    let action = PredicateAwareAction(
      id: toShelf ? "share-to-via-shelf" : "share-to",
      title: toShelf ? "Cloud Share to Shelf via…" : "Cloud Share to…"
    ) { subject, target in
      await share([subject], to: target, toShelf: toShelf)
    }
    action.batchCallback = { subjects, target in
      await share(subjects, to: target, toShelf: toShelf)
    }
    action.systemSymbolName = "icloud.and.arrow.up"
    action.supportedSubjectTypes = [.file, .image]
    action.targetRequirement = .required
    action.allowedTargetTypes = [.cloudShareDestination]
    action.targetSearchScope = .catalogs([CloudShareExtension.catalogIdentifier])
    // Picking among one destination is noise; plain Cloud Share covers it.
    action.subjectPredicate = {
      CloudShareUpload.canShare($0)
        && CloudShareSettings.destinationCount(for: CloudShareActionsCatalog.self) > 1
    }
    action.targetPredicate = { $0 is CloudShareDestinationItem }
    if !toShelf { action.executionPolicy = .resultDriven }
    return action
  }

  /// Problems found before uploading (no destination, nothing uploadable) come back as a
  /// message result so Tuna stays open and says what is wrong; a bare failure only beeps.
  @MainActor
  private static func share(_ subjects: [CatalogItem], to target: CatalogItem?, toShelf: Bool)
    async -> ActionResult
  {
    let destination: CloudShareDestination
    do {
      if let target {
        guard let item = target as? CloudShareDestinationItem else {
          return message("Choose a Cloud Share destination")
        }
        destination = item.destination
      } else {
        destination = try CloudShareSettings.defaultDestination(for: CloudShareActionsCatalog.self)
      }
    } catch CloudShareDestinationError.noDestinations {
      return .results([CloudShareCatalogSupport.noDestinationsItem()])
    } catch {
      return message(error.localizedDescription)
    }

    let uploads = subjects.compactMap(CloudShareUpload.init(item:))
    guard !uploads.isEmpty else { return message("Select a file or image to share") }

    guard toShelf else {
      switch await upload(uploads, to: destination) {
      case .success(let results): return .subjects(results)
      case .failure(let shared, let error):
        return .results(shared + [CloudShareCatalogSupport.errorItem(error, title: "Couldn't Cloud Share")])
      }
    }

    let title = uploads.count == 1
      ? "Sharing \(uploads[0].filename) to \(destination.name)"
      : "Sharing \(uploads.count) files to \(destination.name)"
    return .background(
      CommandBackgroundTask(title: title) {
        switch await upload(uploads, to: destination) {
        case .success(let results): return .success(results: results)
        case .failure(_, let error): return .failure(message: error)
        }
      }
    )
  }

  private static func message(_ text: String) -> ActionResult {
    .results([CloudShareCatalogSupport.errorItem(text, title: "Couldn't Cloud Share")])
  }

  private enum UploadOutcome {
    case success([CatalogItem])
    /// What was shared before the failure, and the failure's description.
    case failure([CatalogItem], String)
  }

  /// Uploads in order, copies every link that made it (one per line), and refreshes the listing.
  /// A partial batch still copies its links so it is useful, but reports the failure.
  private static func upload(_ uploads: [CloudShareUpload], to destination: CloudShareDestination)
    async -> UploadOutcome
  {
    let client = CloudShareS3Client(destination: destination)
    var results: [CatalogItem] = []
    var failure: Error?
    for upload in uploads {
      do {
        let key = CloudShareFilename.key(for: upload.filename, destination: destination)
        let source = try upload.materialize()
        defer { source.cleanUp() }
        try await client.putObject(fileURL: source.url, key: key, contentType: upload.contentType)
        results.append(
          CloudShareObjectItem(
            object: CloudShareObject(key: key, size: source.size, lastModified: Date()),
            destination: destination
          ))
      } catch {
        failure = error
        break
      }
    }
    await copyURLs(of: results)
    CloudShareListingStore.shared.invalidate(destinationID: destination.id)
    guard let failure else { return .success(results) }
    let prefix = results.isEmpty ? "" : "Shared \(results.count) of \(uploads.count). "
    return .failure(results, prefix + failure.localizedDescription)
  }

  private static func copyURLs(of items: [CatalogItem]) async {
    let urls = items.compactMap { ($0 as? CloudShareObjectItem)?.publicURL.absoluteString }
    guard !urls.isEmpty else { return }
    await MainActor.run {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
    }
  }

  // MARK: - Delete

  private static func deleteAction() -> CatalogAction {
    let action = PredicateAwareAction(id: "delete", title: "Delete from Cloud") { subject, _ in
      delete([subject])
    }
    action.batchCallback = { subjects, _ in delete(subjects) }
    action.systemSymbolName = "trash"
    action.supportedSubjectTypes = [.cloudShareObject]
    action.subjectPredicate = { $0 is CloudShareObjectItem }
    action.executionPolicy = .keepVisible
    return action
  }

  @MainActor
  private static func delete(_ subjects: [CatalogItem]) -> ActionResult {
    let items = subjects.compactMap { $0 as? CloudShareObjectItem }
    guard !items.isEmpty else { return .failure("Select a Cloud Shared file") }

    let rows = items.map {
      ActionReviewRow(id: $0.id, title: $0.object.key, detail: $0.destination.name)
    }
    return .review(
      ActionReviewSession(
        presentation: ActionReviewPresentation(
          title: items.count == 1 ? "Delete from Cloud?" : "Delete \(items.count) Files from Cloud?",
          message: "Anyone with the link will no longer be able to open it. This can't be undone.",
          sections: [ActionReviewSection(id: "files", title: "Files", rows: rows)],
          confirmButtonTitle: "Delete",
          isDestructive: true
        )
      ) { response in
        guard case .confirm(let selected) = response else { return .success }
        var failures: [String] = []
        for item in items where selected.contains(item.id) {
          do {
            try await CloudShareS3Client(destination: item.destination)
              .deleteObject(key: item.object.key)
          } catch {
            failures.append("\(item.object.key): \(error.localizedDescription)")
          }
          CloudShareListingStore.shared.invalidate(destinationID: item.destination.id)
        }
        await MainActor.run {
          NotificationCenter.default.post(
            name: CatalogDidFinishScan, object: CloudShareExtension.catalogIdentifier)
        }
        return failures.isEmpty ? .success : .failure(failures.joined(separator: "\n"))
      }
    )
  }

  // MARK: - Test

  private static func testAction() -> CatalogAction {
    let action = PredicateAwareAction(id: "test", title: "Test Destination") { subject, _ in
      guard let item = subject as? CloudShareDestinationItem else {
        return .failure("Select a Cloud Share destination")
      }
      let destination = item.destination
      return .background(
        CommandBackgroundTask(title: "Testing \(destination.name)") {
          do {
            try await CloudShareProbe.run(destination)
            return .successWithoutResult(
              standardOutput: "\(destination.name) uploads, serves, and deletes files.")
          } catch {
            return .failure(message: error.localizedDescription)
          }
        }
      )
    }
    action.systemSymbolName = "checkmark.icloud"
    action.supportedSubjectTypes = [.cloudShareDestination]
    action.subjectPredicate = { $0 is CloudShareDestinationItem }
    return action
  }
}

/// Uploads a small file, fetches it through the public URL, and deletes it again.
enum CloudShareProbe {
  static func run(_ destination: CloudShareDestination, session: URLSession = .shared)
    async throws
  {
    let client = CloudShareS3Client(destination: destination, session: session)
    let body = "Tuna Cloud Share test \(UUID().uuidString)\n"
    var generator = SystemRandomNumberGenerator()
    let name = "tuna-cloud-share-test-\(CloudShareFilename.randomString(length: 8, generator: &generator)).txt"
    let prefix = destination.listingPrefix
    let key = prefix + name

    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try Data(body.utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try await client.putObject(fileURL: fileURL, key: key, contentType: "text/plain; charset=utf-8")
    do {
      let publicURL = destination.publicURL(forKey: key)
      let served = try await client.fetchPublic(publicURL)
      guard served == Data(body.utf8) else {
        throw CloudShareS3Error.publicURLMismatch(publicURL)
      }
    } catch {
      try? await client.deleteObject(key: key)
      throw error
    }
    try await client.deleteObject(key: key)
  }
}

/// One subject prepared for upload: a file on disk or an in-memory image.
struct CloudShareUpload: Sendable {
  enum Source: Sendable {
    case file(URL)
    case png(Data)
  }

  struct Materialized {
    let url: URL
    let size: Int64
    let isTemporary: Bool

    func cleanUp() {
      if isTemporary { try? FileManager.default.removeItem(at: url) }
    }
  }

  let source: Source
  let filename: String
  let contentType: String

  @MainActor
  static func canShare(_ item: CatalogItem?) -> Bool {
    guard let item else { return false }
    if fileURL(for: item) != nil { return true }
    return TypeRegistry.shared.inherits(item.typeID, from: .image)
  }

  @MainActor
  init?(item: CatalogItem) {
    if let url = Self.fileURL(for: item) {
      source = .file(url)
      filename = url.lastPathComponent
      contentType = Self.contentType(for: url)
      return
    }
    guard TypeRegistry.shared.inherits(item.typeID, from: .image),
      let image = item.image(size: 16_384) ?? item.preview(maxDimension: 16_384).image,
      let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return nil }
    source = .png(png)
    let title = CloudShareFilename.sanitize(item.title)
    filename = "\(title.isEmpty ? "image" : title).png"
    contentType = "image/png"
  }

  func materialize() throws -> Materialized {
    switch source {
    case .file(let url):
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
      return Materialized(url: url, size: size, isTemporary: false)
    case .png(let data):
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tuna-cloud-share-\(UUID().uuidString).png")
      try data.write(to: url)
      return Materialized(url: url, size: Int64(data.count), isTemporary: true)
    }
  }

  /// Regular files only: folders would need zipping first.
  private static func fileURL(for item: CatalogItem) -> URL? {
    let registry = TypeRegistry.shared
    guard registry.inherits(item.typeID, from: .file) || registry.inherits(item.typeID, from: .image),
      let path = (item as? CatalogEntity)?.path, path.hasPrefix("/")
    else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  private static func contentType(for url: URL) -> String {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
      ?? UTType(filenameExtension: url.pathExtension)
    guard let mime = type?.preferredMIMEType else { return "application/octet-stream" }
    return mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime
  }
}
