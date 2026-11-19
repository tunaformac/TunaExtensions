import AppKit
import Foundation
import TunaKit

@MainActor
public final class SpotifyControlsCatalog: NSObject, Catalog, RescanSchedulingCatalog {
  static let playbackNotification = Notification.Name("com.spotify.client.PlaybackStateChanged")

  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?

  private var playerItems: [CatalogItem] = []
  private var accountItems: [CatalogItem] = []
  private var observer: NSObjectProtocol?
  private var accountObserver: NSObjectProtocol?
  private var refreshTask: Task<Void, Never>?

  public var objects: [CatalogItem] { playerItems + accountItems }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
    observer = DistributedNotificationCenter.default().addObserver(
      forName: Self.playbackNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRefresh() }
    }
    accountObserver = SpotifyCatalogSupport.observeAccount { [weak self] in self?.rescanHandler?() }
  }

  deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    refreshTask?.cancel()
  }

  public func scan() async {
    let isInstalled = SpotifyAppleScript.isInstalled()
    let nowPlaying = await Task.detached(priority: .utility) {
      try? SpotifyAppleScript.nowPlaying()
    }.value
    playerItems = Self.playerItems(isInstalled: isInstalled, nowPlaying: nowPlaying ?? nil)
    accountItems = SpotifyCatalogSupport.accountCommands()
    reportScanFinished()
  }

  nonisolated static func playerItems(isInstalled: Bool, nowPlaying: SpotifyNowPlaying?)
    -> [CatalogItem]
  {
    guard isInstalled else {
      return [
        CatalogMessageItem(
          title: "Spotify Isn’t Installed",
          message: "Install the Spotify app to control playback from Tuna.",
          symbolName: "exclamationmark.triangle",
          tintColor: .systemOrange
        )
      ]
    }
    return (nowPlaying.map { [SpotifyNowPlayingItem(nowPlaying: $0)] } ?? []) + makeCommands()
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.rescanHandler?()
    }
  }

  nonisolated static func makeCommands() -> [CatalogItem] {
    SpotifyTransport.commands.map { id, title, symbol, detail, run in
      CommandItem(
        id: id,
        title: title,
        symbol: symbol,
        detail: detail,
        tintColor: .systemGreen,
        headlessEligibility: .guaranteed,
        executionPolicy: .dismiss
      ) {
        SpotifyActions.perform(run)
      }
    }
  }
}

@MainActor
public final class SpotifySearchCatalog: NSObject, Catalog {
  public let identifier: String
  public let name: String

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Spotify",
    id: "spotify.search",
    detail: "Search tracks, albums, artists, and playlists",
    catalogIcon: .init(symbolName: "music.note", color: .green),
    childrenProvider: { SpotifyCatalogSupport.accountItem().map { [$0] } ?? [] },
    searchHandler: { query in
      if let accountItem = SpotifyCatalogSupport.accountItem() { return [accountItem] }
      do {
        let resources = try await SpotifyAPIClient().search(query)
        return resources.isEmpty
          ? [
            SpotifyCatalogSupport.emptyItem("No Results", "Nothing on Spotify matched your search.")
          ]
          : resources.map { SpotifyItem.make($0, catalogIdentifier: "spotify.search") }
      } catch {
        return [SpotifyCatalogSupport.messageItem(for: error)]
      }
    }
  )

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
  }

  public func scan() async {
    reportScanFinished()
  }
}

@MainActor
public final class SpotifyLibraryCatalog: NSObject, Catalog, RescanSchedulingCatalog,
  RetainedCatalogStateReleasing
{
  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?
  private var accountObserver: NSObjectProtocol?

  private lazy var rootItem = DeferredBrowseCatalogItem(
    title: "Your Library",
    id: "spotify.library",
    detail: "Saved music and playlists on Spotify",
    catalogIcon: .init(symbolName: "books.vertical", color: .green),
    loadingItemProvider: { SpotifyCatalogSupport.loadingItem("Library") },
    errorItemProvider: { SpotifyCatalogSupport.messageItem(for: $0) },
    didLoad: { [identifier] in
      NotificationCenter.default.post(name: CatalogDidFinishScan, object: identifier)
    },
    loadChildren: {
      if let accountItem = SpotifyCatalogSupport.accountItem() { return [accountItem] }
      return Self.sections(catalogIdentifier: "spotify.library")
    }
  )

  public var objects: [CatalogItem] { [rootItem] }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
    accountObserver = SpotifyCatalogSupport.observeAccount { [weak self] in self?.rescanHandler?() }
  }

  deinit {
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
  }

  public func scan() async {
    rootItem.reset()
    reportScanFinished()
  }

  public func releaseRetainedState() { rootItem.reset() }

  nonisolated static func sections(catalogIdentifier: String) -> [CatalogItem] {
    [
      section(
        "Saved Tracks", id: "tracks", detail: "Tracks saved to your library", symbol: "music.note",
        catalogIdentifier: catalogIdentifier
      ) {
        try await SpotifyAPIClient().savedTracks()
      },
      section(
        "Saved Albums", id: "albums", detail: "Albums saved to your library",
        symbol: "square.stack", catalogIdentifier: catalogIdentifier
      ) {
        try await SpotifyAPIClient().savedAlbums()
      },
      section(
        "Artists", id: "artists", detail: "Artists you follow", symbol: "music.mic",
        catalogIdentifier: catalogIdentifier
      ) {
        try await SpotifyAPIClient().followedArtists()
      },
      section(
        "Playlists", id: "playlists", detail: "Your Spotify playlists", symbol: "music.note.list",
        catalogIdentifier: catalogIdentifier
      ) {
        try await SpotifyAPIClient().playlists()
      },
    ]
  }

  nonisolated private static func section(
    _ title: String,
    id: String,
    detail: String,
    symbol: String,
    catalogIdentifier: String,
    load: @escaping @Sendable () async throws -> [SpotifyResource]
  ) -> CatalogItem {
    DeferredBrowseCatalogItem(
      title: title,
      id: "spotify.library.\(id)",
      detail: detail,
      catalogIcon: .init(symbolName: symbol, color: .green),
      loadingItemProvider: { SpotifyCatalogSupport.loadingItem(title) },
      errorItemProvider: { SpotifyCatalogSupport.messageItem(for: $0) },
      didLoad: {
        NotificationCenter.default.post(name: CatalogDidFinishScan, object: catalogIdentifier)
      },
      loadChildren: {
        let resources = try await load()
        return resources.isEmpty
          ? [
            SpotifyCatalogSupport.emptyItem("No \(title)", "This Spotify library section is empty.")
          ]
          : resources.map { SpotifyItem.make($0, catalogIdentifier: catalogIdentifier) }
      }
    )
  }
}

@MainActor
public final class SpotifyPlaylistsCatalog: NSObject, Catalog, RescanSchedulingCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?
  private var items: [CatalogItem] = []
  private var accountObserver: NSObjectProtocol?

  public var objects: [CatalogItem] { items }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
    accountObserver = SpotifyCatalogSupport.observeAccount { [weak self] in self?.rescanHandler?() }
  }

  deinit {
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
  }

  public func scan() async {
    do {
      items = try await SpotifyAPIClient().playlists().map {
        SpotifyItem.make($0, catalogIdentifier: SpotifyExtension.playlistsCatalogIdentifier)
      }
    } catch {
      items = [SpotifyCatalogSupport.messageItem(for: error)]
    }
    reportScanFinished()
  }
}

@MainActor
public final class SpotifyDevicesCatalog: NSObject, Catalog, RescanSchedulingCatalog,
  StartupScanningCatalog
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var rescanHandler: (() -> Void)?
  private var items: [CatalogItem] = []
  private var accountObserver: NSObjectProtocol?

  public var objects: [CatalogItem] { items }

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
    accountObserver = SpotifyCatalogSupport.observeAccount { [weak self] in self?.rescanHandler?() }
  }

  deinit {
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
  }

  public func scan() async {
    do {
      let devices = try await SpotifyAPIClient().devices().filter { !$0.isRestricted }
      items =
        devices.isEmpty
        ? [SpotifyCatalogSupport.emptyItem("No Devices", "Open Spotify on a device and try again.")]
        : devices.map(SpotifyDeviceItem.init)
    } catch {
      items = [SpotifyCatalogSupport.messageItem(for: error)]
    }
    reportScanFinished()
  }
}
