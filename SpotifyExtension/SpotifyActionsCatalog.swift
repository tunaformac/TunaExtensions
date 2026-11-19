import AppKit
import Foundation
import TunaKit

public final class SpotifyActionsCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
    super.init()
  }

  static let resourceTypes: Set<TypeID> = [
    .spotifyTrack, .spotifyAlbum, .spotifyArtist, .spotifyPlaylist,
  ]

  static func makeActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let play = PredicateAwareAction(id: "play", title: "Play") { subject, _ in
      SpotifyActions.play(subject)
    }
    play.systemSymbolName = "play.fill"
    play.supportedSubjectTypes = resourceTypes.union([.url])
    play.subjectPredicate = {
      $0 is SpotifyNowPlayingItem || SpotifyActions.spotifyURI(of: $0) != nil
    }
    items.append(play)

    let save = PredicateAwareAction(id: "save", title: "Save to Library") { subject, _ in
      SpotifyActions.setSaved(true, subject)
    }
    save.systemSymbolName = "plus.circle"
    save.supportedSubjectTypes = [.spotifyTrack, .spotifyAlbum]
    save.subjectPredicate = { subject in
      if let item = subject as? SpotifyItem { return item.resource.isSaved != true }
      // Now Playing comes from the app, so saving it needs a Web API sign-in.
      return (subject as? SpotifyNowPlayingItem)?.resource != nil && SpotifyAuth.isSignedIn
    }
    items.append(save)

    let remove = PredicateAwareAction(id: "remove-from-library", title: "Remove from Library") {
      subject, _ in
      SpotifyActions.setSaved(false, subject)
    }
    remove.systemSymbolName = "minus.circle"
    remove.supportedSubjectTypes = [.spotifyTrack, .spotifyAlbum]
    remove.subjectPredicate = { ($0 as? SpotifyItem)?.resource.isSaved == true }
    items.append(remove)

    let addToPlaylist = PredicateAwareAction(id: "add-to-playlist", title: "Add to Playlist") {
      subject, target in
      SpotifyActions.add([subject], to: target)
    }
    addToPlaylist.batchCallback = { subjects, target in SpotifyActions.add(subjects, to: target) }
    addToPlaylist.targetRequirement = .required
    addToPlaylist.systemSymbolName = "text.badge.plus"
    addToPlaylist.supportedSubjectTypes = [.spotifyTrack, .spotifyAlbum]
    addToPlaylist.allowedTargetTypes = [.spotifyPlaylist]
    addToPlaylist.targetSearchScope = .catalogs(
      [SpotifyExtension.playlistsCatalogIdentifier], preparation: .refresh)
    addToPlaylist.subjectPredicate = { $0 is SpotifyItem }
    addToPlaylist.targetPredicate = {
      ($0 as? SpotifyItem)?.resource.canModifyPlaylist == true
    }
    items.append(addToPlaylist)

    let queue = PredicateAwareAction(id: "add-to-queue", title: "Add to Queue") { subject, _ in
      SpotifyActions.addToQueue(subject)
    }
    queue.systemSymbolName = "text.line.last.and.arrowtriangle.forward"
    queue.supportedSubjectTypes = [.spotifyTrack]
    queue.subjectPredicate = { ($0 as? SpotifyItem)?.resource.kind == .track }
    items.append(queue)

    let transfer = PredicateAwareAction(id: "transfer-playback", title: "Play on Device") {
      subject, target in
      SpotifyActions.transferPlayback(subject, to: target)
    }
    transfer.targetRequirement = .required
    transfer.systemSymbolName = "hifispeaker.2"
    transfer.supportedSubjectTypes = [.application, .spotifyTrack]
    transfer.allowedTargetTypes = [.spotifyDevice]
    transfer.targetSearchScope = .catalogs(
      [SpotifyExtension.devicesCatalogIdentifier], preparation: .refresh)
    transfer.subjectPredicate = {
      (SpotifyActions.isSpotifyApplication($0) || $0 is SpotifyNowPlayingItem)
        && SpotifyAuth.isSignedIn
    }
    transfer.targetPredicate = { ($0 as? SpotifyDeviceItem)?.device.isRestricted == false }
    items.append(transfer)

    let open = PredicateAwareAction(id: "open-in-spotify", title: "Open in Spotify") { subject, _ in
      SpotifyActions.open(subject)
    }
    open.systemSymbolName = "arrow.up.right.square"
    open.supportedSubjectTypes = resourceTypes.union([.url])
    open.subjectPredicate = { SpotifyActions.spotifyURI(of: $0) != nil }
    items.append(open)

    for command in SpotifyTransport.commands {
      let action = PredicateAwareAction(id: command.id, title: command.title) { _, _ in
        SpotifyActions.perform(command.run)
      }
      action.systemSymbolName = command.symbol
      action.supportedSubjectTypes = [.application]
      action.subjectPredicate = SpotifyActions.isSpotifyApplication
      items.append(action)
    }

    return items
  }
}

/// Playback commands for the Spotify app, shared by the controls catalog and app actions.
enum SpotifyTransport {
  typealias Command = (
    id: String, title: String, symbol: String, detail: String, run: @Sendable () throws -> Void
  )

  static let commands: [Command] = [
    (
      "play-pause", "Play/Pause", "playpause", "Play or pause Spotify",
      { try SpotifyAppleScript.playPause() }
    ),
    (
      "next-track", "Next Track", "forward.end", "Skip to the next track",
      { try SpotifyAppleScript.nextTrack() }
    ),
    (
      "previous-track", "Previous Track", "backward.end", "Go back to the previous track",
      { try SpotifyAppleScript.previousTrack() }
    ),
    (
      "toggle-shuffle", "Toggle Shuffle", "shuffle", "Turn shuffle on or off",
      { try SpotifyAppleScript.toggleShuffle() }
    ),
    (
      "toggle-repeat", "Toggle Repeat", "repeat", "Turn repeat on or off",
      { try SpotifyAppleScript.toggleRepeat() }
    ),
  ]
}

enum SpotifyActions {
  /// Runs an Apple Event in the background; fails right away when Spotify isn't installed.
  static func perform(_ work: @escaping @Sendable () throws -> Void) -> ActionResult {
    guard SpotifyAppleScript.isInstalled() else {
      return .failure(SpotifyScriptError.notInstalled.localizedDescription)
    }
    Task.detached(priority: .userInitiated) {
      do { try work() } catch { report(error) }
    }
    return .success
  }

  static func perform(_ work: @escaping @Sendable () async throws -> Void) -> ActionResult {
    Task.detached(priority: .userInitiated) {
      do { try await work() } catch { report(error) }
    }
    return .success
  }

  /// Plays in the Spotify app on this Mac, or on the active device through the Web API when the
  /// app isn't installed here.
  static func play(_ subject: CatalogItem) -> ActionResult {
    if subject is SpotifyNowPlayingItem { return perform { try SpotifyAppleScript.playPause() } }
    guard let uri = spotifyURI(of: subject)?.uri else {
      return .failure("Select something from Spotify")
    }
    if !SpotifyAppleScript.isInstalled(), SpotifyAuth.isSignedIn {
      return perform { try await SpotifyAPIClient().play(uri: uri) }
    }
    return perform { try SpotifyAppleScript.play(uri: uri) }
  }

  static func setSaved(_ saved: Bool, _ subject: CatalogItem) -> ActionResult {
    guard
      let resource = (subject as? SpotifyItem)?.resource
        ?? (subject as? SpotifyNowPlayingItem)?.resource
    else {
      return .failure("Select something from Spotify")
    }
    return perform { try await SpotifyAPIClient().setSaved(saved, resource: resource) }
  }

  static func add(_ subjects: [CatalogItem], to target: CatalogItem?) -> ActionResult {
    let resources = subjects.compactMap { ($0 as? SpotifyItem)?.resource }
    guard !resources.isEmpty, let playlist = (target as? SpotifyItem)?.resource else {
      return .failure("Select Spotify tracks or albums and a playlist")
    }
    return perform { try await SpotifyAPIClient().add(resources, to: playlist) }
  }

  static func addToQueue(_ subject: CatalogItem) -> ActionResult {
    guard let resource = (subject as? SpotifyItem)?.resource else {
      return .failure("Select a Spotify track")
    }
    return perform { try await SpotifyAPIClient().addToQueue(resource) }
  }

  static func transferPlayback(_ subject: CatalogItem, to target: CatalogItem?) -> ActionResult {
    guard isSpotifyApplication(subject) || subject is SpotifyNowPlayingItem,
      let device = (target as? SpotifyDeviceItem)?.device
    else { return .failure("Select a Spotify device") }
    return perform { try await SpotifyAPIClient().transferPlayback(to: device) }
  }

  static func open(_ subject: CatalogItem) -> ActionResult {
    guard let url = spotifyURI(of: subject)?.webURL else {
      return .failure("No Spotify link available")
    }
    guard
      let appURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: SpotifyAppleScript.bundleIdentifier)
    else {
      NSWorkspace.shared.open(url)
      return .success
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    return .success
  }

  static func spotifyURI(of subject: CatalogItem?) -> SpotifyURI? {
    if let item = subject as? SpotifyItem { return SpotifyURI(item.resource.uri) }
    if let item = subject as? SpotifyNowPlayingItem { return SpotifyURI(item.nowPlaying.uri) }
    if let text = (subject as? TextValueProviding)?.textValue, let uri = SpotifyURI(text) {
      return uri
    }
    return (subject as? CatalogEntity)?.path.flatMap(SpotifyURI.init)
  }

  static func isSpotifyApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
      == SpotifyAppleScript.bundleIdentifier
  }

  private static func report(_ error: Error) {
    AppLog.error(.actions, "Spotify action failed: \(error.localizedDescription)")
    UserFeedback.beep()
  }
}
