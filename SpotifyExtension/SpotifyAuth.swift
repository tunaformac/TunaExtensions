import AppKit
import Foundation
import TunaKit

/// The Web API side of the extension runs on the user's own Spotify app: they paste its client ID
/// into the extension's settings and sign in with Authorization Code + PKCE through a loopback
/// redirect. Tokens stay in the Keychain and refresh directly against Spotify.
enum SpotifyAuth {
  static let providerIdentifier = "spotify"
  static let clientIDSettingKey = "ClientID"
  static let redirectHost = "127.0.0.1"
  static let redirectPath = "/callback"
  /// What users register in their Spotify app. Spotify lets loopback redirects take any port,
  /// so the sign-in adds the port it actually listens on.
  static let registeredRedirectURI = "http://127.0.0.1/callback"
  static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
  static let setupGuideURL = URL(
    string: "https://github.com/tunaformac/TunaExtensions/tree/main/SpotifyExtension#web-api-setup")!
  static let authorizationURL = URL(string: "https://accounts.spotify.com/authorize")!
  static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
  static let scopes = [
    "playlist-modify-private",
    "playlist-modify-public",
    "playlist-read-collaborative",
    "playlist-read-private",
    "user-follow-read",
    "user-library-modify",
    "user-library-read",
    "user-modify-playback-state",
    "user-read-playback-state",
  ]
  static let accountDidChange = Notification.Name("SpotifyAccountDidChange")

  static let clientIDSetting = CatalogSettingDefinition(
    key: clientIDSettingKey,
    type: .string,
    label: "Client ID",
    defaultValue: "",
    description: """
      Optional. Search, Your Library, saving, playlists, and queueing use your own Spotify app:
      1. Create an app at developer.spotify.com/dashboard (needs Spotify Premium).
      2. Pick Web API and add the redirect URI http://127.0.0.1/callback.
      3. Paste its Client ID here, then run Sign In to Spotify in Tuna.
      """
  )

  static var extensionIdentifier: String {
    Bundle(for: SpotifyExtension.self).bundleIdentifier ?? "TunaSpotify"
  }

  static func clientID(
    store: CatalogSettingStore = CatalogSettingStore(catalogIdentifier: extensionIdentifier)
  ) -> String? {
    let value = store.stringValue(for: clientIDSetting)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  static func connectionStore() -> ExtensionConnectionStore {
    ExtensionConnectionStore(
      extensionIdentifier: extensionIdentifier, providerIdentifier: providerIdentifier)
  }

  static func configuration(clientID: String) -> OAuthPKCEConfiguration {
    OAuthPKCEConfiguration(
      clientIdentifier: clientID,
      authorizationURL: authorizationURL,
      tokenURL: tokenURL,
      scopes: scopes
    )
  }

  static func redirectURI(port: UInt16) -> URL {
    URL(string: "http://\(redirectHost):\(port)\(redirectPath)")!
  }

  enum State: Equatable {
    case needsClientID
    case needsSignIn
    case signedIn(ExtensionConnectionRecord)
  }

  static func state() -> State {
    guard let clientID = clientID() else { return .needsClientID }
    guard let record = record(for: clientID, in: connectionStore().records()) else {
      return .needsSignIn
    }
    return .signedIn(record)
  }

  static var isSignedIn: Bool {
    if case .signedIn = state() { return true }
    return false
  }

  /// The connection made with `clientID`. Connections from the old shared Tuna app (or another
  /// client ID) can't be refreshed with it, so they count as signed out.
  static func record(for clientID: String, in records: [ExtensionConnectionRecord])
    -> ExtensionConnectionRecord?
  {
    records.first { $0.workspaceID == clientID }
  }

  static func signOut() {
    let store = connectionStore()
    for record in store.records() {
      try? store.delete(recordID: record.id)
    }
    postAccountDidChange()
  }

  static func postAccountDidChange() {
    Task { @MainActor in
      NotificationCenter.default.post(name: accountDidChange, object: nil)
    }
  }
}

// MARK: - Tokens

struct SpotifyToken: Equatable, Sendable {
  let accessToken: String
  let refreshToken: String?
  let scopes: [String]
  let expiresIn: TimeInterval?
}

/// Talks to Spotify's token endpoint. PKCE public clients send their client ID and no secret.
struct SpotifyTokenClient: Sendable {
  typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  var send: Send = { try await URLSession.shared.data(for: $0) }

  func exchange(code: String, verifier: String, redirectURI: URL, clientID: String) async throws
    -> SpotifyToken
  {
    try await requestToken([
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectURI.absoluteString,
      "client_id": clientID,
      "code_verifier": verifier,
    ])
  }

  func refresh(_ refreshToken: String, clientID: String) async throws -> SpotifyToken {
    try await requestToken([
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": clientID,
    ])
  }

  private func requestToken(_ parameters: [String: String]) async throws -> SpotifyToken {
    let (data, response) = try await send(Self.request(parameters))
    guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }
    return try Self.parse(data: data, statusCode: http.statusCode)
  }

  static func request(_ parameters: [String: String]) -> URLRequest {
    var components = URLComponents()
    components.queryItems = parameters.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    var request = URLRequest(url: SpotifyAuth.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // `+` is legal in a query but means a space in a form body.
    request.httpBody = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    return request
  }

  static func parse(data: Data, statusCode: Int) throws -> SpotifyToken {
    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard (200..<300).contains(statusCode) else {
      let error = payload["error"] as? String
      let description = payload["error_description"] as? String
      switch (statusCode, error) {
      case (_, "invalid_grant"): throw SpotifyAPIError.reconnectRequired
      case (_, "invalid_client"): throw SpotifyAPIError.invalidClientID
      case (429, _): throw SpotifyAPIError.rateLimited
      default: throw SpotifyAPIError.unexpectedStatus(statusCode, description ?? error)
      }
    }
    guard let accessToken = payload["access_token"] as? String, !accessToken.isEmpty else {
      throw SpotifyAPIError.invalidResponse
    }
    let refreshToken = (payload["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let scopes = (payload["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
    return SpotifyToken(
      accessToken: accessToken,
      refreshToken: refreshToken,
      scopes: scopes,
      expiresIn: (payload["expires_in"] as? NSNumber)?.doubleValue
    )
  }
}

/// A signed-in connection and its tokens.
struct SpotifySession: Equatable, Sendable {
  var record: ExtensionConnectionRecord
  var accessToken: String
  var refreshToken: String?

  var clientID: String? { record.workspaceID }
}

/// Where sessions live. The live storage keeps records in Tuna's connection store (tokens in the
/// Keychain); tests swap in memory.
struct SpotifySessionStorage: Sendable {
  var clientID: @Sendable () -> String?
  var load: @Sendable (_ clientID: String) -> SpotifySession?
  var save: @Sendable (SpotifySession) throws -> Void
  var deleteAll: @Sendable () -> Void

  static let live = SpotifySessionStorage(
    clientID: { SpotifyAuth.clientID() },
    load: { clientID in
      let store = SpotifyAuth.connectionStore()
      guard let record = SpotifyAuth.record(for: clientID, in: store.records()),
        let accessToken = store.accessToken(for: record), !accessToken.isEmpty
      else { return nil }
      return SpotifySession(
        record: record, accessToken: accessToken, refreshToken: store.refreshToken(for: record))
    },
    save: { session in
      try SpotifyAuth.connectionStore().save(
        session.record,
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        makeDefault: true
      )
    },
    deleteAll: { SpotifyAuth.signOut() }
  )
}

actor SpotifyTokenManager {
  static let shared = SpotifyTokenManager()

  /// Refresh this long before Spotify's one-hour access tokens run out.
  static let refreshMargin: TimeInterval = 60

  private let storage: SpotifySessionStorage
  private let tokenClient: SpotifyTokenClient
  private let now: @Sendable () -> Date
  private var refreshTask: Task<SpotifySession, Error>?

  init(
    storage: SpotifySessionStorage = .live,
    tokenClient: SpotifyTokenClient = SpotifyTokenClient(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.storage = storage
    self.tokenClient = tokenClient
    self.now = now
  }

  func session(forceRefresh: Bool = false) async throws -> SpotifySession {
    guard let clientID = storage.clientID() else { throw SpotifyAPIError.missingClientID }
    guard let session = storage.load(clientID) else { throw SpotifyAPIError.missingConnection }
    if !forceRefresh, !Self.needsRefresh(expiresAt: session.record.expiresAt, now: now()) {
      return session
    }

    if let refreshTask { return try await refreshTask.value }
    let task = Task { try await refresh(session, clientID: clientID) }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  static func needsRefresh(expiresAt: Date?, now: Date) -> Bool {
    guard let expiresAt else { return false }
    return expiresAt <= now.addingTimeInterval(refreshMargin)
  }

  private func refresh(_ session: SpotifySession, clientID: String) async throws -> SpotifySession
  {
    guard let refreshToken = session.refreshToken else {
      storage.deleteAll()
      throw SpotifyAPIError.reconnectRequired
    }
    let token: SpotifyToken
    do {
      token = try await tokenClient.refresh(refreshToken, clientID: clientID)
    } catch let error as SpotifyAPIError where error.endsSession {
      // Refresh tokens last six months from sign-in; after that (or once revoked) only a new
      // sign-in helps, so drop the dead tokens.
      storage.deleteAll()
      throw error
    }

    var updated = session
    updated.accessToken = token.accessToken
    updated.refreshToken = token.refreshToken ?? refreshToken
    updated.record.expiresAt = token.expiresIn.map { now().addingTimeInterval($0) }
    if !token.scopes.isEmpty { updated.record.scopes = token.scopes }
    try storage.save(updated)
    return updated
  }
}

// MARK: - Sign in

enum SpotifySignInError: LocalizedError {
  case denied(String)
  case stateMismatch
  case timedOut
  case listenerFailed(String)

  var errorDescription: String? {
    switch self {
    case .denied(let reason):
      return reason == "access_denied" ? "Spotify sign-in was cancelled." : "Spotify said: \(reason)"
    case .stateMismatch:
      return "Spotify sent back a sign-in Tuna didn’t start. Try again."
    case .timedOut:
      return "Spotify sign-in timed out. Try again."
    case .listenerFailed(let message):
      return "Couldn’t wait for Spotify’s sign-in redirect: \(message)"
    }
  }
}

enum SpotifySignIn {
  static let timeout: TimeInterval = 5 * 60

  @MainActor
  static func start() -> ActionResult {
    guard let clientID = SpotifyAuth.clientID() else {
      NSWorkspace.shared.open(SpotifyAuth.setupGuideURL)
      return .failure("Add your Spotify client ID in Tuna’s Spotify settings first")
    }
    return .background(
      CommandBackgroundTask(title: "Signing in to Spotify") {
        do {
          let record = try await signIn(clientID: clientID)
          return .successWithoutResult(standardOutput: "Signed in as \(record.trimmedDisplayName)")
        } catch {
          return .failure(message: error.localizedDescription)
        }
      }
    )
  }

  static func signIn(clientID: String) async throws -> ExtensionConnectionRecord {
    let pair = PKCE.generate()
    let state = UUID().uuidString.lowercased()
    let receiver = try await SpotifyLoopbackReceiver.start(path: SpotifyAuth.redirectPath)
    defer { receiver.stop() }

    let redirectURI = SpotifyAuth.redirectURI(port: receiver.port)
    guard
      let authorizeURL = SpotifyAuth.configuration(clientID: clientID).makeAuthorizationURL(
        redirectURI: redirectURI, state: state, pair: pair)
    else { throw SpotifyAPIError.invalidResponse }
    await MainActor.run { _ = NSWorkspace.shared.open(authorizeURL) }

    let callbackURL = try await receiver.waitForCallback(timeout: timeout)
    let code = try authorizationCode(from: callbackURL, redirectURI: redirectURI, state: state)
    let token = try await SpotifyTokenClient().exchange(
      code: code, verifier: pair.verifier, redirectURI: redirectURI, clientID: clientID)
    let profile = try await SpotifyAPIClient.profile(accessToken: token.accessToken)

    let record = makeRecord(clientID: clientID, token: token, profile: profile, now: Date())
    // One account at a time; this also clears connections from the old shared app.
    let store = SpotifyAuth.connectionStore()
    for existing in store.records() {
      try? store.delete(recordID: existing.id)
    }
    try store.save(
      record, accessToken: token.accessToken, refreshToken: token.refreshToken, makeDefault: true)
    SpotifyAuth.postAccountDidChange()
    return record
  }

  static func authorizationCode(from callbackURL: URL, redirectURI: URL, state: String) throws
    -> String
  {
    guard let callback = OAuthAuthorizationCallback(url: callbackURL, callbackURL: redirectURI)
    else { throw SpotifyAPIError.invalidResponse }
    switch callback.result {
    case .authorization(let code, let returnedState):
      guard returnedState == state else { throw SpotifySignInError.stateMismatch }
      return code
    case .failure(let message, let returnedState):
      guard returnedState == state else { throw SpotifySignInError.stateMismatch }
      throw SpotifySignInError.denied(message)
    @unknown default:
      throw SpotifyAPIError.invalidResponse
    }
  }

  /// The record keys on Spotify's stable `account_id` and keeps the user `id` for playlist
  /// ownership checks. `workspaceID` holds the client ID the tokens were issued to.
  static func makeRecord(
    clientID: String, token: SpotifyToken, profile: SpotifyProfile, now: Date
  ) -> ExtensionConnectionRecord {
    ExtensionConnectionRecord(
      id: profile.accountID ?? profile.id,
      providerIdentifier: SpotifyAuth.providerIdentifier,
      displayName: profile.displayName ?? profile.id,
      userID: profile.id,
      userName: profile.displayName,
      workspaceID: clientID,
      scopes: token.scopes.isEmpty ? SpotifyAuth.scopes : token.scopes,
      expiresAt: token.expiresIn.map { now.addingTimeInterval($0) },
      createdAt: now,
      updatedAt: now
    )
  }
}
