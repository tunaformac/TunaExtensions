import AppKit
import Foundation
import TunaKit
import UniformTypeIdentifiers

public final class MyMindActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeActions() -> [CatalogAction] {
    let save = PredicateAwareAction(id: "save", title: "Save to mymind") { subject, _ in
      await performSave(subject, to: nil)
    }
    save.systemSymbolName = "brain.head.profile"
    save.executionPolicy = .resultDriven
    // Capture is additive, not the primary handler for any built-in subject type.
    save.supportedSubjectTypes = [.entity]
    save.subjectPredicate = { canCapture($0) }

    let saveToSpace = PredicateAwareAction(
      id: "save-to-space", title: "Save to mymind space"
    ) { subject, target in
      guard let space = target as? MyMindSpaceItem else {
        return .failure("Choose a mymind Space")
      }
      return await performSave(subject, to: space)
    }
    saveToSpace.targetRequirement = .required
    saveToSpace.systemSymbolName = "square.grid.2x2"
    saveToSpace.executionPolicy = .resultDriven
    saveToSpace.supportedSubjectTypes = [.entity]
    saveToSpace.allowedTargetTypes = [.myMindSpace]
    saveToSpace.targetSearchScope = .catalogs(["mymind.spaces"], preparation: .refresh)
    saveToSpace.subjectPredicate = { canCapture($0) }
    saveToSpace.targetPredicate = { $0 is MyMindSpaceItem }

    let openOriginal = PredicateAwareAction(id: "open-original", title: "Open Original") {
      subject, _ in
      guard let item = subject as? MyMindObjectItem, let url = item.object.sourceURL else {
        return .failure("This mymind object does not have an original URL")
      }
      NSWorkspace.shared.open(url)
      return .success
    }
    openOriginal.systemSymbolName = "arrow.up.right.square"
    openOriginal.supportedSubjectTypes = [.myMindObject]
    openOriginal.subjectPredicate = {
      ($0 as? MyMindObjectItem)?.object.sourceURL != nil
    }

    return [save, saveToSpace, openOriginal, MyMindResolveAction()]
  }

  @MainActor
  private static func performSave(
    _ subject: CatalogItem, to space: MyMindSpaceItem?
  ) async -> ActionResult {
    guard let capture = capture(from: subject) else {
      return .failure("Select a URL, text, image, PDF, or supported file to save")
    }

    let credentials: MyMindCredentials
    do {
      credentials = try MyMindSettings.credentials(for: MyMindActionsCatalog.self)
    } catch {
      return .failure(error.localizedDescription)
    }
    guard credentials.accessLevel.canWrite else {
      return .failure(MyMindAPIError.readOnlyKey.localizedDescription)
    }

    do {
      let object = try await MyMindAPIClient(credentials: credentials)
        .createObject(capture, spaceID: space?.space.id)
      return .results([URLItem(urlString: object.accessURLString)])
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  static func canCapture(_ item: CatalogItem?) -> Bool {
    guard let item else { return false }
    if httpURL(from: item) != nil || fileUpload(from: item) != nil { return true }
    if TypeRegistry.shared.inherits(item.typeID, from: .image) { return true }
    return item.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  static func capture(from item: CatalogItem?) -> MyMindCapture? {
    guard let item else { return nil }

    if let url = httpURL(from: item) { return .url(url) }

    if let upload = fileUpload(from: item) { return .upload(upload) }

    if TypeRegistry.shared.inherits(item.typeID, from: .image),
      let image = item.image(size: 16_384) ?? item.preview(maxDimension: 16_384).image,
      let data = pngData(from: image)
    {
      return .upload(
        MyMindUpload(
          body: .data(data),
          filename: "\(MyMindCatalogSupport.safeFilename(item.title, fallback: "Tuna Image")).png",
          contentType: "image/png"
        )
      )
    }

    let value = item.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return nil }
    return .content(value)
  }

  private static func httpURL(from item: CatalogItem) -> URL? {
    let url = (item as? URLPreviewSourceProviding)?.previewURL
      ?? item.textInputValue().flatMap(URL.init(string:))
    guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  private static func fileUpload(from item: CatalogItem) -> MyMindUpload? {
    let registry = TypeRegistry.shared
    guard registry.inherits(item.typeID, from: .file)
      || registry.inherits(item.typeID, from: .image),
      let entity = item as? CatalogEntity,
      let path = entity.path
    else { return nil }

    let url = URL(fileURLWithPath: path)
    guard let contentType = supportedContentType(for: url) else { return nil }
    return MyMindUpload(body: .file(url), filename: url.lastPathComponent, contentType: contentType)
  }

  static func supportedContentType(for url: URL) -> String? {
    let detected = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
      ?? UTType(filenameExtension: url.pathExtension)
    guard let mime = detected?.preferredMIMEType else { return nil }
    if mime == "image/heic" { return "image/heif" }
    return supportedMIMETypes.contains(mime) ? mime : nil
  }

  private static let supportedMIMETypes: Set<String> = [
    "image/jpeg", "image/png", "image/gif", "image/webp", "image/avif", "image/heif",
    "image/heic", "image/jxl", "image/bmp", "image/tiff", "image/vnd.adobe.photoshop",
    "image/svg+xml", "text/plain", "text/markdown", "application/pdf", "video/mp4",
    "video/quicktime", "video/webm", "video/x-msvideo", "video/x-matroska",
  ]

  private static func pngData(from image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }
}

private final class MyMindResolveAction: CatalogAction, ActionPredicateProviding,
  @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate? = { $0 is MyMindObjectItem }
  var targetPredicate: CatalogActionTargetPredicate?

  init() {
    super.init(id: "resolve", title: "Resolve", executionPolicy: .keepVisible) {
      subject, target in
      await Self.perform(subjects: [subject], target: target)
    }
    batchCallback = { subjects, target in
      await Self.perform(subjects: subjects, target: target)
    }
    systemSymbolName = "arrow.down.circle"
    supportedSubjectTypes = [.myMindObject]
  }

  private static func perform(subjects: [CatalogItem], target: CatalogItem?) async -> ActionResult {
    do {
      let resolved = try await subjects.asyncMap { subject -> CatalogItem in
        guard let item = subject as? MyMindObjectItem else {
          throw MyMindResolutionError.unsupportedObject
        }
        return try await MyMindObjectResolver.shared.resolve(item)
      }
      return resolved.isEmpty ? .failure("Nothing to resolve") : .subjects(resolved)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private extension Array {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var results: [T] = []
    results.reserveCapacity(count)
    for element in self { results.append(try await transform(element)) }
    return results
  }
}
