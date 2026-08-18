//
//  CleanShotCommandsCatalog.swift
//  CleanShotExtension
//
//  CleanShot X quick commands via URL schemes.
//

import AppKit
import Foundation
import ImageIO
import TunaKit

public final class CleanShotCommandsCatalog: Catalog, CatalogSortingProviding {
  public let identifier: String
  public let name: String
  public let sortOptions = [CatalogSortOption.capturedAtDescending]

  private let objectsStore = LockedValue<[CatalogItem]>([])
  private lazy var recentCapturesItem = DeferredBrowseCatalogItem(
    title: "Recent Captures",
    id: "cleanshot.recent-captures",
    detail: "Browse recent CleanShot images",
    catalogIcon: BrowseCatalogItem.CatalogIcon(
      symbolName: "photo.on.rectangle.angled",
      color: .orange
    ),
    childResultsPresentation: .grid(
      CatalogGridConfiguration(
        columns: 4,
        minimumCellSize: 88,
        maximumCellSize: 140,
        spacing: 4,
        padding: 4,
        cellPadding: 8
      )
    ),
    loadingItemProvider: {
      CatalogLoadingItem(
        title: "Loading Recent Captures",
        message: "Scanning CleanShot’s local media library."
      )
    },
    errorItemProvider: { error in
      CatalogMessageItem(
        title: "Couldn’t load recent captures",
        message: error.localizedDescription,
        symbolName: "exclamationmark.triangle",
        tintColor: .systemOrange
      )
    },
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: {
      let captures = try CleanShotMediaLibrary.recentCaptures()
      guard captures.isEmpty else { return captures }
      return [
        CatalogMessageItem(
          title: "No recent captures",
          message: "CleanShot’s local media library contains no images.",
          symbolName: "photo",
          tintColor: .secondaryLabelColor
        )
      ]
    }
  )

  public var objects: [CatalogItem] {
    objectsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    recentCapturesItem.reset()
    objectsStore.value = [recentCapturesItem] + Self.makeCommands()
  }

  private static func makeCommands() -> [CatalogItem] {
    let commands: [CommandDefinition] = [
      CommandDefinition(
        id: "all-in-one-capture",
        title: "All-in-One Capture",
        detail: "Open CleanShot's all-in-one picker",
        symbol: "camera.viewfinder",
        command: "all-in-one"
      ),
      CommandDefinition(
        id: "capture-area",
        title: "Capture Area",
        detail: "Capture a selection",
        symbol: "rectangle.dashed",
        command: "capture-area"
      ),
      CommandDefinition(
        id: "capture-window",
        title: "Capture Window",
        detail: "Capture a window",
        symbol: "macwindow",
        command: "capture-window"
      ),
      CommandDefinition(
        id: "capture-full-screen",
        title: "Capture Full Screen",
        detail: "Capture the full screen",
        symbol: "rectangle",
        command: "capture-fullscreen"
      ),
      CommandDefinition(
        id: "capture-previous-area",
        title: "Capture Previous Area",
        detail: "Capture the last selection again",
        symbol: "arrow.clockwise",
        command: "capture-previous-area"
      ),
      CommandDefinition(
        id: "scrolling-capture",
        title: "Scrolling Capture",
        detail: "Capture a scrolling area",
        symbol: "arrow.up.and.down",
        command: "scrolling-capture"
      ),
      CommandDefinition(
        id: "self-timer-capture",
        title: "Self Timer Capture",
        detail: "Capture after a short timer",
        symbol: "timer",
        command: "self-timer"
      ),
      CommandDefinition(
        id: "record-screen",
        title: "Record Screen",
        detail: "Start screen recording",
        symbol: "record.circle",
        command: "record-screen"
      ),
      CommandDefinition(
        id: "capture-text-ocr",
        title: "Capture Text (OCR)",
        detail: "Extract text from the screen",
        symbol: "text.magnifyingglass",
        command: "capture-text"
      ),
      CommandDefinition(
        id: "open-history",
        title: "Open History",
        detail: "Show CleanShot history",
        symbol: "clock.arrow.circlepath",
        command: "open-history"
      ),
      CommandDefinition(
        id: "open-annotate",
        title: "Open Annotate",
        detail: "Open the annotate window",
        symbol: "square.and.pencil",
        command: "open-annotate"
      ),
      CommandDefinition(
        id: "annotate-from-clipboard",
        title: "Annotate from Clipboard",
        detail: "Open annotate with clipboard image",
        symbol: "doc.on.clipboard",
        command: "open-from-clipboard"
      ),
      CommandDefinition(
        id: "restore-recently-closed",
        title: "Restore Recently Closed",
        detail: "Restore the last closed capture",
        symbol: "arrow.uturn.backward",
        command: "restore-recently-closed"
      ),
      CommandDefinition(
        id: "toggle-desktop-icons",
        title: "Toggle Desktop Icons",
        detail: "Show or hide desktop icons",
        symbol: "desktopcomputer",
        command: "toggle-desktop-icons"
      ),
      CommandDefinition(
        id: "hide-desktop-icons",
        title: "Hide Desktop Icons",
        detail: "Hide desktop icons",
        symbol: "eye.slash",
        command: "hide-desktop-icons"
      ),
      CommandDefinition(
        id: "show-desktop-icons",
        title: "Show Desktop Icons",
        detail: "Show desktop icons",
        symbol: "eye",
        command: "show-desktop-icons"
      ),
      CommandDefinition(
        id: "open-settings",
        title: "Open Settings",
        detail: "Open CleanShot settings",
        symbol: "gearshape",
        command: "open-settings"
      ),
    ]

    return commands.compactMap { command -> CatalogItem? in
      guard let url = command.url else { return nil }
      return CommandItem(
        id: command.id,
        title: command.title,
        symbol: command.symbol,
        detail: command.detail,
        tintColor: .systemOrange,
        headlessEligibility: .guaranteed,
        executionPolicy: .dismiss
      ) {
        guard URIOpener.open(url) else {
          return .failure("CleanShot X is not available")
        }
        return .success
      }
    }
  }
}

private final class CleanShotCaptureItem: FileSystemEntity, CatalogAsyncPreviewProviding,
  CatalogGridPreviewProviding, @unchecked Sendable
{
  init(fileURL: URL, modifiedAt: Date) {
    super.init(
      displayName: fileURL.deletingPathExtension().lastPathComponent,
      url: fileURL,
      kind: .file,
      capturedAtDate: modifiedAt
    )
    updatePreviewIdentityVersion(from: modifiedAt)
  }

  override var detail: String? {
    capturedAtDate.formatted(date: .abbreviated, time: .shortened)
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("photo", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func asyncPreview(maxDimension: CGFloat) async -> CatalogItemPreview? {
    let fileURL = url
    return await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(maxDimension))),
      ]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      else { return nil }
      let image = NSImage(
        cgImage: thumbnail,
        size: NSSize(width: thumbnail.width, height: thumbnail.height)
      )
      return CatalogItemPreview(image: image)
    }.value
  }
}

enum CleanShotMediaLibrary {
  static let maximumCaptureCount = 100

  private static let imageExtensions: Set<String> = [
    "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
  ]

  static func recentCaptures(fileManager: FileManager = .default) throws -> [CatalogItem] {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else { return [] }

    let mediaDirectory = applicationSupport
      .appendingPathComponent("CleanShot", isDirectory: true)
      .appendingPathComponent("media", isDirectory: true)
    return try recentCaptures(in: mediaDirectory, fileManager: fileManager)
  }

  static func recentCaptures(
    in mediaDirectory: URL,
    limit: Int = maximumCaptureCount,
    fileManager: FileManager = .default
  ) throws -> [CatalogItem] {
    guard limit > 0 else { return [] }
    guard fileManager.fileExists(atPath: mediaDirectory.path) else { return [] }
    let resourceKeys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isRegularFileKey,
      .contentModificationDateKey,
    ]
    let entries = try fileManager.contentsOfDirectory(
      at: mediaDirectory,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    )

    let preparedEntries = entries.compactMap { url -> (URL, URLResourceValues)? in
      guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
      return (url, values)
    }

    var captures: [(url: URL, modifiedAt: Date)] = []
    for (entryURL, values) in preparedEntries {
      if values.isRegularFile == true {
        appendImage(entryURL, values: values, limit: limit, to: &captures)
      } else if values.isDirectory == true {
        let files = try fileManager.contentsOfDirectory(
          at: entryURL,
          includingPropertiesForKeys: Array(resourceKeys),
          options: [.skipsHiddenFiles]
        )
        for fileURL in files {
          guard let fileValues = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
          appendImage(fileURL, values: fileValues, limit: limit, to: &captures)
        }
      }
    }

    return captures
      .sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(limit)
      .map { CleanShotCaptureItem(fileURL: $0.url, modifiedAt: $0.modifiedAt) }
  }

  private static func appendImage(
    _ url: URL,
    values: URLResourceValues,
    limit: Int,
    to captures: inout [(url: URL, modifiedAt: Date)]
  ) {
    guard values.isRegularFile == true else { return }
    guard imageExtensions.contains(url.pathExtension.lowercased()) else { return }
    captures.append((url, values.contentModificationDate ?? .distantPast))
    guard captures.count > limit,
      let oldestIndex = captures.indices.min(by: {
        captures[$0].modifiedAt < captures[$1].modifiedAt
      })
    else { return }
    captures.remove(at: oldestIndex)
  }
}

private struct CommandDefinition {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let command: String

  var url: URL? {
    URL(string: "cleanshot://\(command)")
  }
}
