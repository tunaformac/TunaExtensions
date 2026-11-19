import Foundation

struct SpotifyResource: Sendable {
  enum Kind: String, Sendable {
    case track
    case album
    case artist
    case playlist
  }

  let kind: Kind
  let id: String
  let title: String
  let subtitle: String
  let uri: String
  let externalURL: URL
  let artworkURL: URL?
  let isSaved: Bool?
  let isBrowsable: Bool
  let canModifyPlaylist: Bool
}

struct SpotifyDevice: Sendable {
  let id: String
  let name: String
  let type: String
  let isActive: Bool
  let isRestricted: Bool
}

struct SpotifyProfile: Equatable, Sendable {
  let id: String
  let displayName: String?
  /// Spotify's stable account identifier (added May 2026); `id` may change.
  let accountID: String?

  init?(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, !id.isEmpty else { return nil }
    self.id = id
    displayName = (payload["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    accountID = (payload["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
  }
}

enum SpotifyAPIError: LocalizedError, Equatable {
  case missingClientID
  case missingConnection
  case reconnectRequired
  case invalidClientID
  case notAllowlisted
  case premiumRequired
  case noActiveDevice
  case rateLimited
  case unexpectedStatus(Int, String?)
  case invalidResponse

  var title: String {
    switch self {
    case .missingClientID: return "Set Up Spotify Web API"
    case .missingConnection: return "Sign In to Spotify"
    case .reconnectRequired: return "Sign In to Spotify Again"
    case .invalidClientID: return "Spotify Client ID Not Recognized"
    case .notAllowlisted: return "Spotify Account Not Allowed"
    case .premiumRequired: return "Spotify Premium Required"
    case .noActiveDevice: return "No Active Spotify Device"
    case .rateLimited: return "Spotify Rate Limit Reached"
    case .unexpectedStatus: return "Spotify Request Failed"
    case .invalidResponse: return "Spotify Response Error"
    }
  }

  var errorDescription: String? {
    switch self {
    case .missingClientID:
      return "Add your own Spotify app’s client ID in Tuna’s Spotify settings."
    case .missingConnection:
      return "Sign in to Spotify to search and browse your library."
    case .reconnectRequired:
      return "Spotify sign-ins last six months. Sign in again to keep using your library."
    case .invalidClientID:
      return "Check the client ID in Tuna’s Spotify settings against your Spotify app."
    case .notAllowlisted:
      return "Add this Spotify account under User Management in your Spotify app’s settings."
    case .premiumRequired:
      return "Spotify requires Premium for this playback action."
    case .noActiveDevice:
      return "Start Spotify on a device, then try again."
    case .rateLimited:
      return "Spotify is receiving too many requests. Try again shortly."
    case .unexpectedStatus(let code, let message):
      return message ?? "Spotify returned HTTP \(code)."
    case .invalidResponse:
      return "Could not parse Spotify’s response."
    }
  }

  /// Errors after which the stored tokens are useless and only a new sign-in helps.
  var endsSession: Bool {
    self == .reconnectRequired || self == .invalidClientID
  }

  /// Whether the fix is signing in (or setting up) rather than retrying.
  var needsAccountSetup: Bool {
    switch self {
    case .missingClientID, .missingConnection, .reconnectRequired, .invalidClientID: return true
    default: return false
    }
  }
}

struct SpotifyAPIClient: Sendable {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  /// The signed-in user, read with a fresh access token during sign-in. Needs no scope.
  static func profile(accessToken: String, session: URLSession = .shared) async throws
    -> SpotifyProfile
  {
    var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }
    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (200..<300).contains(http.statusCode) else {
      throw error(status: http.statusCode, payload: payload, path: "/v1/me")
    }
    guard let profile = SpotifyProfile(payload) else { throw SpotifyAPIError.invalidResponse }
    return profile
  }

  func search(_ query: String, limit: Int = 8) async throws -> [SpotifyResource] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let payload = try await request(
      path: "/v1/search",
      query: [
        URLQueryItem(name: "q", value: trimmed),
        URLQueryItem(name: "type", value: "track,album,artist,playlist"),
        URLQueryItem(name: "limit", value: String(max(1, min(limit, 10)))),
      ]
    )
    return [
      resources(in: payload, container: "tracks", kind: .track),
      resources(in: payload, container: "albums", kind: .album, isBrowsable: true),
      resources(in: payload, container: "artists", kind: .artist, isBrowsable: true),
      resources(in: payload, container: "playlists", kind: .playlist),
    ].flatMap { $0 }
  }

  func savedTracks(limit: Int = 50) async throws -> [SpotifyResource] {
    let payload = try await request(
      path: "/v1/me/tracks", query: [URLQueryItem(name: "limit", value: String(limit))])
    return items(payload).compactMap { item in
      (item["track"] as? [String: Any]).flatMap { parse($0, kind: .track, isSaved: true) }
    }
  }

  func savedAlbums(limit: Int = 50) async throws -> [SpotifyResource] {
    let payload = try await request(
      path: "/v1/me/albums", query: [URLQueryItem(name: "limit", value: String(limit))])
    return items(payload).compactMap { item in
      (item["album"] as? [String: Any]).flatMap {
        parse($0, kind: .album, isSaved: true, isBrowsable: true)
      }
    }
  }

  func followedArtists(limit: Int = 50) async throws -> [SpotifyResource] {
    let payload = try await request(
      path: "/v1/me/following",
      query: [
        URLQueryItem(name: "type", value: "artist"),
        URLQueryItem(name: "limit", value: String(limit)),
      ]
    )
    return resources(
      in: payload, container: "artists", kind: .artist, isSaved: true, isBrowsable: true)
  }

  func playlists(limit: Int = 50) async throws -> [SpotifyResource] {
    let userID = try await SpotifyTokenManager.shared.session().record.userID
    let payload = try await request(
      path: "/v1/me/playlists", query: [URLQueryItem(name: "limit", value: String(limit))])
    return items(payload).compactMap {
      let ownerID = ($0["owner"] as? [String: Any])?["id"] as? String
      let canModify =
        (ownerID != nil && ownerID == userID) || $0["collaborative"] as? Bool == true
      return parse(
        $0,
        kind: .playlist,
        isSaved: true,
        isBrowsable: canModify,
        canModifyPlaylist: canModify
      )
    }
  }

  func tracks(in resource: SpotifyResource) async throws -> [SpotifyResource] {
    switch resource.kind {
    case .track:
      return [resource]
    case .album:
      let payload = try await request(
        path: "/v1/albums/\(resource.id)/tracks", query: [URLQueryItem(name: "limit", value: "50")])
      return items(payload).compactMap {
        parse($0, kind: .track, inheritedArtworkURL: resource.artworkURL)
      }
    case .playlist:
      let payload = try await request(
        path: "/v1/playlists/\(resource.id)/items",
        query: [URLQueryItem(name: "limit", value: "50")])
      return items(payload).compactMap { item in
        let raw = (item["item"] ?? item["track"]) as? [String: Any]
        return raw.flatMap { parse($0, kind: .track) }
      }
    case .artist:
      return []
    }
  }

  func children(of resource: SpotifyResource) async throws -> [SpotifyResource] {
    if resource.kind != .artist { return try await tracks(in: resource) }
    let payload = try await request(
      path: "/v1/artists/\(resource.id)/albums",
      query: [
        URLQueryItem(name: "include_groups", value: "album,single"),
        URLQueryItem(name: "limit", value: "50"),
      ]
    )
    return items(payload).compactMap { parse($0, kind: .album, isBrowsable: true) }
  }

  func devices() async throws -> [SpotifyDevice] {
    let payload = try await request(path: "/v1/me/player/devices")
    return (payload["devices"] as? [[String: Any]] ?? []).compactMap { device in
      guard let id = device["id"] as? String, let name = device["name"] as? String else {
        return nil
      }
      return SpotifyDevice(
        id: id,
        name: name,
        type: device["type"] as? String ?? "Device",
        isActive: device["is_active"] as? Bool ?? false,
        isRestricted: device["is_restricted"] as? Bool ?? false
      )
    }
  }

  func transferPlayback(to device: SpotifyDevice) async throws {
    guard !device.isRestricted else {
      throw SpotifyAPIError.unexpectedStatus(
        403, "Spotify doesn’t allow playback control on this device.")
    }
    _ = try await request(
      path: "/v1/me/player",
      method: "PUT",
      body: ["device_ids": [device.id], "play": true]
    )
  }

  func setSaved(_ saved: Bool, resource: SpotifyResource) async throws {
    guard resource.kind == .track || resource.kind == .album else { return }
    _ = try await request(
      path: "/v1/me/library",
      method: saved ? "PUT" : "DELETE",
      query: [URLQueryItem(name: "uris", value: resource.uri)]
    )
  }

  func add(_ resources: [SpotifyResource], to playlist: SpotifyResource) async throws {
    var uris: [String] = []
    for resource in resources {
      uris.append(contentsOf: try await tracks(in: resource).map(\.uri))
    }
    guard !uris.isEmpty else { return }
    for batch in stride(from: 0, to: uris.count, by: 100) {
      let end = min(batch + 100, uris.count)
      _ = try await request(
        path: "/v1/playlists/\(playlist.id)/items",
        method: "POST",
        body: ["uris": Array(uris[batch..<end])]
      )
    }
  }

  /// Starts playback on the active device; used when the Spotify app isn't installed here.
  func play(uri: String) async throws {
    let isSingleItem = uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:")
    _ = try await request(
      path: "/v1/me/player/play",
      method: "PUT",
      body: isSingleItem ? ["uris": [uri]] : ["context_uri": uri]
    )
  }

  func addToQueue(_ resource: SpotifyResource) async throws {
    _ = try await request(
      path: "/v1/me/player/queue", method: "POST",
      query: [URLQueryItem(name: "uri", value: resource.uri)]
    )
  }

  private func request(
    path: String,
    method: String = "GET",
    query: [URLQueryItem] = [],
    body: [String: Any]? = nil,
    attempt: Int = 0,
    forceRefresh: Bool = false
  ) async throws -> [String: Any] {
    let account = try await SpotifyTokenManager.shared.session(forceRefresh: forceRefresh)
    var components = URLComponents(string: "https://api.spotify.com\(path)")!
    components.queryItems = query.isEmpty ? nil : query
    var urlRequest = URLRequest(url: components.url!)
    urlRequest.httpMethod = method
    urlRequest.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    await SpotifyRateLimitGate.shared.waitIfNeeded()
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }
    if http.statusCode == 401, attempt == 0 {
      return try await request(
        path: path, method: method, query: query, body: body, attempt: 1, forceRefresh: true)
    }
    if http.statusCode == 429, attempt == 0 {
      let delay = max(1, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1)
      await SpotifyRateLimitGate.shared.block(for: TimeInterval(delay))
      guard delay <= 30 else { throw SpotifyAPIError.rateLimited }
      await SpotifyRateLimitGate.shared.waitIfNeeded()
      return try await request(path: path, method: method, query: query, body: body, attempt: 1)
    }
    guard (200..<300).contains(http.statusCode) else {
      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      throw Self.error(status: http.statusCode, payload: payload, path: path)
    }
    if data.isEmpty { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  static func error(status: Int, payload: [String: Any], path: String) -> SpotifyAPIError {
    let message = (payload["error"] as? [String: Any])?["message"] as? String
    let isPlayer = path.hasPrefix("/v1/me/player")
    switch status {
    case 401: return .reconnectRequired
    // Development-mode apps answer 403 for Spotify accounts missing from the app's allowlist.
    case 403 where message?.localizedCaseInsensitiveContains("registered") == true:
      return .notAllowlisted
    case 403 where isPlayer: return .premiumRequired
    case 404 where isPlayer: return .noActiveDevice
    case 429: return .rateLimited
    default: return .unexpectedStatus(status, message)
    }
  }

  private func resources(
    in payload: [String: Any],
    container: String,
    kind: SpotifyResource.Kind,
    isSaved: Bool? = nil,
    isBrowsable: Bool = false
  ) -> [SpotifyResource] {
    guard let object = payload[container] as? [String: Any] else { return [] }
    return items(object).compactMap {
      parse($0, kind: kind, isSaved: isSaved, isBrowsable: isBrowsable)
    }
  }

  private func items(_ payload: [String: Any]) -> [[String: Any]] {
    payload["items"] as? [[String: Any]] ?? []
  }

  private func parse(
    _ payload: [String: Any],
    kind: SpotifyResource.Kind,
    isSaved: Bool? = nil,
    inheritedArtworkURL: URL? = nil,
    isBrowsable: Bool = false,
    canModifyPlaylist: Bool = false
  ) -> SpotifyResource? {
    guard let id = payload["id"] as? String, let title = payload["name"] as? String else {
      return nil
    }
    let uri = payload["uri"] as? String ?? "spotify:\(kind.rawValue):\(id)"
    let external = payload["external_urls"] as? [String: Any]
    let urlString =
      external?["spotify"] as? String ?? "https://open.spotify.com/\(kind.rawValue)/\(id)"
    guard let externalURL = URL(string: urlString) else { return nil }
    let artists = (payload["artists"] as? [[String: Any]] ?? []).compactMap {
      $0["name"] as? String
    }
    let album = payload["album"] as? [String: Any]
    let albumName = album?["name"] as? String
    let owner = (payload["owner"] as? [String: Any])?["display_name"] as? String
    let itemCount =
      ((payload["tracks"] as? [String: Any])?["total"] as? Int)
      ?? ((payload["items"] as? [String: Any])?["total"] as? Int)
    let subtitleParts: [String]
    switch kind {
    case .track: subtitleParts = artists + [albumName ?? ""]
    case .album: subtitleParts = artists + ["Album"]
    case .artist: subtitleParts = ["Artist"]
    case .playlist: subtitleParts = [owner ?? "", itemCount.map { "\($0) tracks" } ?? "Playlist"]
    }
    let images =
      (payload["images"] as? [[String: Any]]) ?? (album?["images"] as? [[String: Any]]) ?? []
    let artworkURL =
      images.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }.first
      ?? inheritedArtworkURL
    return SpotifyResource(
      kind: kind,
      id: id,
      title: title,
      subtitle: subtitleParts.filter { !$0.isEmpty }.joined(separator: " · "),
      uri: uri,
      externalURL: externalURL,
      artworkURL: artworkURL,
      isSaved: isSaved,
      isBrowsable: isBrowsable,
      canModifyPlaylist: canModifyPlaylist
    )
  }
}

private actor SpotifyRateLimitGate {
  static let shared = SpotifyRateLimitGate()
  private var blockedUntil = Date.distantPast

  func block(for interval: TimeInterval) {
    blockedUntil = max(blockedUntil, Date().addingTimeInterval(interval))
  }

  func waitIfNeeded() async {
    let delay = blockedUntil.timeIntervalSinceNow
    guard delay > 0 else { return }
    try? await Task.sleep(for: .seconds(delay))
  }
}
