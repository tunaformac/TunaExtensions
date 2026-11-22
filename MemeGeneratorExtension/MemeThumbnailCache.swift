import AppKit
import Foundation
import ImageIO
import TunaKit
import UniformTypeIdentifiers

/// Template thumbnails are downscaled once, stored on disk indefinitely, and prefetched in the
/// background so the grid shows real images instantly and offline.
final class MemeThumbnailCache: @unchecked Sendable {
  static let live = MemeThumbnailCache(
    directory: MemeTemplateLibrary.dataDirectory.appending(path: "thumbnails", directoryHint: .isDirectory),
    session: MemeURLSessions.direct
  )

  static let maxPixelSize = 400
  static let prefetchConcurrency = 6

  let directory: URL
  private let session: URLSession
  private let prefetching = LockedValue(false)

  init(directory: URL, session: URLSession) {
    self.directory = directory
    self.session = session
  }

  func fileURL(for template: MemeTemplate) -> URL {
    let safe = template.key.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
    }.joined()
    return directory.appending(path: "\(safe).jpg")
  }

  func cachedImage(for template: MemeTemplate) -> NSImage? {
    NSImage(contentsOf: fileURL(for: template))
  }

  /// Disk first; otherwise downloads, downscales, and stores the thumbnail.
  func image(for template: MemeTemplate) async -> NSImage? {
    if let image = cachedImage(for: template) { return image }
    guard await download(template) else { return nil }
    return cachedImage(for: template)
  }

  /// Fetches every missing thumbnail in the background, a few at a time. One pass runs at once.
  func prefetch(_ templates: [MemeTemplate]) {
    let missing = templates.filter {
      !FileManager.default.fileExists(atPath: fileURL(for: $0).path)
    }
    guard !missing.isEmpty else { return }
    let shouldStart = prefetching.withValue { running in
      if running { return false }
      running = true
      return true
    }
    guard shouldStart else { return }
    Task.detached(priority: .background) { [self] in
      defer { prefetching.value = false }
      await withTaskGroup(of: Void.self) { group in
        var iterator = missing.makeIterator()
        for _ in 0..<Self.prefetchConcurrency {
          guard let template = iterator.next() else { break }
          group.addTask { _ = await self.download(template) }
        }
        while await group.next() != nil {
          guard let template = iterator.next() else { continue }
          group.addTask { _ = await self.download(template) }
        }
      }
    }
  }

  @discardableResult
  func download(_ template: MemeTemplate) async -> Bool {
    var request = URLRequest(url: template.thumbnailURL)
    request.setValue("image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
    guard
      let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let jpeg = Self.downscaledJPEG(data)
    else { return false }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try jpeg.write(to: fileURL(for: template), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  static func downscaledJPEG(_ data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }
}
