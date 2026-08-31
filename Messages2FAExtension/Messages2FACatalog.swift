import AppKit
import Darwin
import Foundation
import TunaKit

@MainActor
public final class Messages2FACatalog: NSObject, Catalog, CatalogSortingProviding,
  RescanSchedulingCatalog
{
  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?
  public let sortOptions = [CatalogSortOption.capturedAtDescending]

  private let databaseURL: URL
  private var directoryWatcher: DispatchSourceFileSystemObject?
  private var refreshTask: Task<Void, Never>?

  private lazy var browseItem = DeferredBrowseCatalogItem(
    title: "Recent 2FA Codes",
    id: "messages-2fa.recent",
    detail: "Browse recent authentication codes from Messages",
    catalogIcon: .init(symbolName: "message.badge", color: .green),
    loadingItemProvider: {
      CatalogLoadingItem(
        title: "Loading Authentication Codes",
        message: "Reading recent incoming Messages on this Mac."
      )
    },
    errorItemProvider: { error in
      CatalogMessageItem(
        title: "Messages Access Needed",
        message: error.localizedDescription,
        symbolName: "lock.fill",
        tintColor: .systemOrange
      )
    },
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: { [databaseURL] in
      let settings = Messages2FASettings.current
      let messages = try MessagesDatabase.fetchRecentMessages(
        from: databaseURL,
        lookBackMinutes: settings.minutes,
        ignoreRead: settings.ignoreRead
      )
      let items = messages.compactMap(AuthenticationCodeItem.init(message:))
      guard items.isEmpty else { return items }
      return [
        CatalogMessageItem(
          title: "No Recent Codes",
          message: "No authentication codes were found in the selected time window.",
          symbolName: "message",
          tintColor: .secondaryLabelColor
        )
      ]
    }
  )

  public var objects: [CatalogItem] { [browseItem] }

  public required convenience init(definition: CatalogDefinition) {
    self.init(
      identifier: definition.identifier,
      name: definition.name,
      databaseURL: MessagesDatabase.defaultDatabaseURL
    )
  }

  init(identifier: String, name: String = "Messages 2FA", databaseURL: URL) {
    self.identifier = identifier
    self.name = name
    self.databaseURL = databaseURL
    super.init()
  }

  deinit {
    directoryWatcher?.cancel()
    refreshTask?.cancel()
  }

  public func scan() async {
    browseItem.reset()
    installWatcherIfNeeded()
    reportScanFinished()
  }

  private func installWatcherIfNeeded() {
    guard directoryWatcher == nil else { return }
    let directory = databaseURL.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    directoryWatcher = source
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.rescanHandler?()
    }
  }
}
