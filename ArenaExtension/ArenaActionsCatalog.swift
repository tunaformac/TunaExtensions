import AppKit
import Foundation
import TunaKit
import UniformTypeIdentifiers

public final class ArenaActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeActions() -> [CatalogAction] {
    let capture = PredicateAwareAction(
      id: "capture", title: "Save to Are.na", type: .action
    ) { subject, target in
      guard let capture = capture(from: subject) else {
        return .failure("Select a URL, text, or image to save")
      }
      guard let channel = target as? ArenaChannelItem else {
        return .failure("Choose an Are.na channel")
      }
      guard channel.connection.canWrite else {
        return .failure("Reconnect Are.na in extension settings to grant write access")
      }

      let connection = channel.connection
      let channelID = channel.channel.id
      return .background(
        CommandBackgroundTask(title: "Saving to Are.na") {
          do {
            let client = ArenaAPIClient(connection: connection)
            let block = switch capture {
            case .value(let value):
              try await client.createBlock(value: value, channelID: channelID)
            case .upload(let upload):
              try await client.createBlock(upload: upload, channelID: channelID)
            }
            return .success(
              results: [ArenaBlockItem(block: block, connectionID: connection.record.id)])
          } catch {
            return .failure(message: error.localizedDescription)
          }
        })
    }
    capture.targetRequirement = .required
    capture.systemSymbolName = "square.and.arrow.down"
    capture.supportedSubjectTypes = [.url, .textSnippet, .file, .image]
    capture.allowedTargetTypes = [.arenaChannel]
    capture.targetSearchScope = .catalogs(
      [ArenaExtension.catalogIdentifier],
      preparation: .refresh
    )
    capture.subjectPredicate = { canCapture($0) }
    capture.targetPredicate = { $0 is ArenaChannelItem }

    let openChannel = PredicateAwareAction(
      id: "open-channel", title: "Open on Are.na", type: .action
    ) { subject, _ in
      guard let channel = subject as? ArenaChannelItem else {
        return .failure("No Are.na channel selected")
      }
      NSWorkspace.shared.open(channel.channel.url)
      return .success
    }
    openChannel.systemSymbolName = "arrow.up.right.square"
    openChannel.supportedSubjectTypes = [.arenaChannel]
    openChannel.subjectPredicate = { $0 is ArenaChannelItem }

    let openBlock = PredicateAwareAction(
      id: "open-block", title: "Open on Are.na", type: .action
    ) { subject, _ in
      guard let block = subject as? ArenaBlockItem else {
        return .failure("No Are.na block selected")
      }
      NSWorkspace.shared.open(block.block.arenaURL)
      return .success
    }
    openBlock.systemSymbolName = "arrow.up.right.square"
    openBlock.supportedSubjectTypes = [.arenaBlock]
    openBlock.subjectPredicate = { $0 is ArenaBlockItem }

    return [capture, openChannel, openBlock, ArenaResolveAction()]
  }

  private enum Capture: Sendable {
    case value(String)
    case upload(ArenaUpload)
  }

  private static func canCapture(_ item: CatalogItem?) -> Bool {
    guard let item else { return false }
    if TypeRegistry.shared.inherits(item.typeID, from: .image) { return true }
    if imageFileUpload(from: item) != nil { return true }
    return captureValue(from: item) != nil
  }

  private static func capture(from item: CatalogItem?) -> Capture? {
    guard let item else { return nil }
    if let value = captureValue(from: item) { return .value(value) }

    if let upload = imageFileUpload(from: item) {
      return .upload(upload)
    }

    guard TypeRegistry.shared.inherits(item.typeID, from: .image),
      let image = item.image(size: 16_384) ?? item.preview(maxDimension: 16_384).image,
      let data = pngData(from: image)
    else { return nil }
    return .upload(
      ArenaUpload(
        body: .data(data),
        filename: "\(ArenaCatalogSupport.safeFilename(item.title, fallback: "Tuna Image")).png",
        contentType: "image/png"
      ))
  }

  private static func captureValue(from item: CatalogItem) -> String? {
    if TypeRegistry.shared.inherits(item.typeID, from: .url),
      let entity = item as? CatalogEntity,
      let path = entity.path,
      let url = URL(string: path),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      return url.absoluteString
    }

    guard TypeRegistry.shared.inherits(item.typeID, from: .textSnippet) else { return nil }
    let value = item.textValueFallback()?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  private static func imageFileUpload(from item: CatalogItem) -> ArenaUpload? {
    let registry = TypeRegistry.shared
    guard registry.inherits(item.typeID, from: .file)
      || registry.inherits(item.typeID, from: .image),
      let entity = item as? CatalogEntity,
      let path = entity.path
    else { return nil }
    let url = URL(fileURLWithPath: path)
    guard let contentType = imageContentType(for: url) else { return nil }
    return ArenaUpload(
      body: .file(url),
      filename: url.lastPathComponent,
      contentType: contentType
    )
  }

  private static func imageContentType(for url: URL) -> String? {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
      ?? UTType(filenameExtension: url.pathExtension)
    guard let type, type.conforms(to: .image), let contentType = type.preferredMIMEType else {
      return nil
    }
    return contentType
  }

  private static func pngData(from image: NSImage) -> Data? {
    guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }

}

private final class ArenaResolveAction: CatalogAction, AsyncActionProviding,
  ActionPredicateProviding, @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate? = {
    $0 is ArenaBlockItem || $0 is ArenaChannelItem
  }
  var targetPredicate: CatalogActionTargetPredicate?

  init() {
    super.init(id: "resolve", title: "Resolve", type: .action) { _, _ in
      .failure("Nothing to resolve")
    }
    systemSymbolName = "arrow.down.circle"
    supportedSubjectTypes = [.arenaBlock, .arenaChannel]
    producesInlineResult = true
  }

  func performAsync(subjects: [CatalogItem], target: CatalogItem?) async -> ActionResult {
    do {
      var resolved: [CatalogItem] = []
      resolved.reserveCapacity(subjects.count)
      for subject in subjects {
        if let channel = subject as? ArenaChannelItem {
          resolved.append(URLItem(urlString: channel.channel.url.absoluteString))
        } else if let block = subject as? ArenaBlockItem {
          resolved.append(try await ArenaBlockResolver.shared.resolve(block.block))
        } else {
          throw ArenaResolutionError.unsupportedItem
        }
      }
      return resolved.isEmpty ? .failure("Nothing to resolve") : .subjects(resolved)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}
