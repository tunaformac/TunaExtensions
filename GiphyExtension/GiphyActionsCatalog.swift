import AppKit
import Foundation
import TunaKit

public final class GiphyActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = [
    Self.copyURLAction(),
    GiphyResolveAction(),
  ]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func copyURLAction() -> CatalogAction {
    let action = PredicateAwareAction(id: "copy-url", title: "Copy URL") { subject, _ in
      guard let item = subject as? GiphyGIFItem else {
        return .failure("Select a GIPHY GIF to copy")
      }
      let copied = await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(item.gif.originalURL.absoluteString, forType: .string)
      }
      return copied ? .success : .failure("Failed to copy the GIF URL")
    }
    action.systemSymbolName = "link"
    action.supportedSubjectTypes = [.giphyGIF]
    action.subjectPredicate = { $0 is GiphyGIFItem }
    return action
  }
}

private final class GiphyResolveAction: CatalogAction, ActionPredicateProviding,
  @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate? = { $0 is GiphyGIFItem }
  var targetPredicate: CatalogActionTargetPredicate?

  init() {
    super.init(
      id: "resolve",
      title: "Resolve",
      executionPolicy: .keepVisible
    ) { subject, _ in
      await Self.perform(subjects: [subject])
    }
    batchCallback = { subjects, _ in
      await Self.perform(subjects: subjects)
    }
    systemSymbolName = "arrow.down.circle"
    supportedSubjectTypes = [.giphyGIF]
  }

  private static func perform(subjects: [CatalogItem]) async -> ActionResult {
    do {
      var files: [CatalogItem] = []
      for subject in subjects {
        guard let item = subject as? GiphyGIFItem else {
          throw GiphyResolutionError.unsupportedItem
        }
        files.append(try await GiphyResolver.live.resolve(item.gif))
      }
      return files.isEmpty ? .failure("Nothing to resolve") : .subjects(files)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

actor GiphyResolver {
  static let live = GiphyResolver(
    session: GiphyURLSessions.direct,
    directory: FileManager.default.temporaryDirectory
      .appending(path: "Tuna", directoryHint: .isDirectory)
      .appending(path: "GIPHY", directoryHint: .isDirectory)
  )

  private let session: URLSession
  private let directory: URL

  init(session: URLSession, directory: URL) {
    self.session = session
    self.directory = directory
  }

  func resolve(_ gif: GiphyGIF) async throws -> FileSystemEntity {
    let (temporaryURL, response) = try await session.download(from: gif.originalURL)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      response.mimeType?.hasPrefix("image/") != false
    else { throw GiphyResolutionError.downloadFailed }

    let file = try FileHandle(forReadingFrom: temporaryURL)
    defer { try? file.close() }
    let header = try file.read(upToCount: 6)
    guard header == Data("GIF87a".utf8) || header == Data("GIF89a".utf8) else {
      throw GiphyResolutionError.invalidGIF
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appending(path: "giphy-\(Self.safeID(gif.id)).gif")
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: destination)

    return FileSystemEntity(
      displayName: destination.lastPathComponent,
      url: destination,
      kind: .file,
      capturedAtDate: .now
    )
  }

  private static func safeID(_ id: String) -> String {
    let safe = id.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        ? String(scalar)
        : "-"
    }.joined()
    return safe.isEmpty ? UUID().uuidString : safe
  }
}

enum GiphyResolutionError: LocalizedError {
  case unsupportedItem
  case downloadFailed
  case invalidGIF

  var errorDescription: String? {
    switch self {
    case .unsupportedItem: "Select a GIPHY GIF to resolve"
    case .downloadFailed: "Could not download the GIF from GIPHY"
    case .invalidGIF: "GIPHY returned an invalid GIF"
    }
  }
}
