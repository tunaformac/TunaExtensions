import AppKit
import Foundation
import ImageIO
import TunaKit
import UniformTypeIdentifiers

/// Template thumbnails are downscaled once and stored on disk. They're prefetched in the background
/// only after the user opens Make Meme, so the grid then shows real images instantly and offline.
/// File names include a hash of the image URL, so a changed template image gets a new thumbnail, and
/// `prune(keeping:)` removes thumbnails for templates that are gone.
final class MemeThumbnailCache: @unchecked Sendable {
  static let live = MemeThumbnailCache(
    directory: MemeTemplateLibrary.dataDirectory.appending(path: "thumbnails", directoryHint: .isDirectory),
    session: MemeURLSessions.direct
  )

  static let maxPixelSize = 400
  static let prefetchConcurrency = 6

  let directory: URL
  private let session: URLSession
  private let prefetchTask = LockedValue<Task<Void, Never>?>(nil)

  init(directory: URL, session: URLSession) {
    self.directory = directory
    self.session = session
  }

  func fileURL(for template: MemeTemplate) -> URL {
    let safe = template.key.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
    }.joined()
    return directory.appending(path: "\(safe)-\(Self.stableHash(template.thumbnailURL.absoluteString)).jpg")
  }

  /// FNV-1a, so file names stay the same across launches (Swift's `hashValue` is seeded per process).
  static func stableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  var isPrefetching: Bool { prefetchTask.readValue { $0 != nil } }

  func cachedImage(for template: MemeTemplate) -> NSImage? {
    NSImage(contentsOf: fileURL(for: template))
  }

  /// Disk first; otherwise downloads, downscales, and stores the thumbnail.
  func image(for template: MemeTemplate) async -> NSImage? {
    if let image = cachedImage(for: template) { return image }
    guard await download(template) else { return nil }
    return cachedImage(for: template)
  }

  /// Fetches every missing thumbnail in the background, a few at a time. One pass runs at once,
  /// and `cancelPrefetch()` stops it.
  func prefetch(_ templates: [MemeTemplate]) {
    let missing = templates.filter {
      !FileManager.default.fileExists(atPath: fileURL(for: $0).path)
    }
    guard !missing.isEmpty else { return }
    prefetchTask.withValue { task in
      guard task == nil else { return }
      task = Task.detached(priority: .background) { [self] in
        // A cancelled pass was already cleared by `cancelPrefetch()`; don't clear its successor.
        defer { if !Task.isCancelled { prefetchTask.value = nil } }
        await withTaskGroup(of: Void.self) { group in
          var iterator = missing.makeIterator()
          for _ in 0..<Self.prefetchConcurrency {
            guard let template = iterator.next() else { break }
            group.addTask { _ = await self.download(template) }
          }
          while await group.next() != nil {
            guard !Task.isCancelled, let template = iterator.next() else { continue }
            group.addTask { _ = await self.download(template) }
          }
        }
      }
    }
  }

  /// Waits for the current pass, if any (tests).
  func waitForPrefetch() async {
    await prefetchTask.readValue({ $0 })?.value
  }

  func cancelPrefetch() {
    prefetchTask.withValue { task in
      task?.cancel()
      task = nil
    }
  }

  /// Deletes thumbnails that no listed template uses (removed templates, changed images).
  func prune(keeping templates: [MemeTemplate]) {
    let keep = Set(templates.map { fileURL(for: $0).lastPathComponent })
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for file in files where file.pathExtension == "jpg" && !keep.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
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
