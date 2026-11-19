import Foundation
import Testing
import TunaKit

@testable import TunaSpotify

@Suite(.serialized)
struct SpotifyExtensionTests {
  @Test func parsesNowPlaying() {
    let output = [
      "playing",
      "spotify:track:123",
      "Song",
      "Artist",
      "Album",
      "https://i.scdn.co/image/cover",
    ].joined(separator: SpotifyAppleScript.recordSeparator)

    let result = SpotifyAppleScript.parseNowPlaying(output)

    #expect(result?.state == .playing)
    #expect(result?.uri == "spotify:track:123")
    #expect(result?.title == "Song")
    #expect(result?.artist == "Artist")
    #expect(result?.album == "Album")
  }

  @Test func rejectsIncompleteNowPlaying() {
    #expect(SpotifyAppleScript.parseNowPlaying("playing") == nil)
  }

  @Test func escapesAppleScriptLiterals() {
    #expect(SpotifyAppleScript.Scripts.literal("a\\b\"c") == "\"a\\\\b\\\"c\"")
  }

  @Test func onlyResourcesWithAvailableContentsAreBrowsable() {
    let album = SpotifyResource(
      kind: .album,
      id: "album-1",
      title: "Album",
      subtitle: "Artist",
      uri: "spotify:album:album-1",
      externalURL: URL(string: "https://open.spotify.com/album/album-1")!,
      artworkURL: nil,
      isSaved: nil,
      isBrowsable: true,
      canModifyPlaylist: false
    )
    let track = SpotifyResource(
      kind: .track,
      id: "track-1",
      title: "Track",
      subtitle: "Artist",
      uri: "spotify:track:track-1",
      externalURL: URL(string: "https://open.spotify.com/track/track-1")!,
      artworkURL: nil,
      isSaved: nil,
      isBrowsable: false,
      canModifyPlaylist: false
    )
    let publicPlaylist = SpotifyResource(
      kind: .playlist,
      id: "playlist-1",
      title: "Playlist",
      subtitle: "Owner",
      uri: "spotify:playlist:playlist-1",
      externalURL: URL(string: "https://open.spotify.com/playlist/playlist-1")!,
      artworkURL: nil,
      isSaved: nil,
      isBrowsable: false,
      canModifyPlaylist: false
    )

    #expect(SpotifyItem.make(album, catalogIdentifier: "test") is SpotifyCollectionItem)
    #expect(!(SpotifyItem.make(track, catalogIdentifier: "test") is SpotifyCollectionItem))
    #expect(!(SpotifyItem.make(publicPlaylist, catalogIdentifier: "test") is SpotifyCollectionItem))
  }

  // MARK: Local controls

  @Test func transportCommandsMapToSpotifyScripts() throws {
    let scripts = ScriptRecorder()
    SpotifyAppleScript.isInstalledOverride = { true }
    SpotifyAppleScript.runOverride = { scripts.append($0); return "" }
    defer { resetOverrides() }

    for command in SpotifyTransport.commands { try command.run() }
    try SpotifyAppleScript.play(uri: "spotify:album:abc\"")

    let bodies = scripts.values.map {
      $0.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }[1]
    }
    #expect(SpotifyTransport.commands.map(\.id) == [
      "play-pause", "next-track", "previous-track", "toggle-shuffle", "toggle-repeat",
    ])
    #expect(bodies == [
      "playpause",
      "next track",
      "previous track",
      "set shuffling to not shuffling",
      "set repeating to not repeating",
      "play track \"spotify:album:abc\\\"\"",
    ])
    #expect(scripts.values.allSatisfy { $0.hasPrefix("tell application \"Spotify\"") })
  }

  @Test func scriptsNeverRunWithoutSpotifyInstalled() {
    let scripts = ScriptRecorder()
    SpotifyAppleScript.isInstalledOverride = { false }
    SpotifyAppleScript.runOverride = { scripts.append($0); return "" }
    defer { resetOverrides() }

    #expect(throws: SpotifyScriptError.self) { try SpotifyAppleScript.playPause() }
    #expect(scripts.values.isEmpty)
    if case .failure(let message) = SpotifyActions.perform({ try SpotifyAppleScript.nextTrack() }) {
      #expect(message?.contains("isn’t installed") == true)
    } else {
      Issue.record("Expected a failure when Spotify isn’t installed")
    }
  }

  @Test func controlsSayWhenSpotifyIsMissing() {
    let missing = SpotifyControlsCatalog.playerItems(isInstalled: false, nowPlaying: nil)
    #expect(missing.count == 1)
    #expect(missing.first?.title == "Spotify Isn’t Installed")

    let nowPlaying = SpotifyNowPlaying(
      state: .paused, uri: "spotify:track:abc", title: "Song", artist: "Artist", album: "Album",
      artworkURL: nil)
    let installed = SpotifyControlsCatalog.playerItems(isInstalled: true, nowPlaying: nowPlaying)
    #expect(installed.first is SpotifyNowPlayingItem)
    #expect(installed.dropFirst().map(\.id) == SpotifyTransport.commands.map(\.id))
  }

  @Test func parsesSpotifyURIsAndLinks() {
    #expect(SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.uri == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
    #expect(
      SpotifyURI("https://open.spotify.com/intl-de/album/1DFixLWuPkv3KT3TnV35m3?si=xyz")?.uri
        == "spotify:album:1DFixLWuPkv3KT3TnV35m3")
    #expect(
      SpotifyURI("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.webURL.absoluteString
        == "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")
    #expect(SpotifyURI("spotify:local:Artist:Album:Song:180") == nil)
    #expect(SpotifyURI("spotify:user:me") == nil)
    #expect(SpotifyURI("https://example.com/track/abc") == nil)
    #expect(SpotifyURI("http://open.spotify.com/track/abc") == nil)
  }

  // MARK: PKCE sign-in

  @Test func pkceChallengeMatchesRFC7636() {
    #expect(
      PKCE.makeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let pair = PKCE.generate()
    #expect((43...128).contains(pair.verifier.count))
    #expect(pair.challenge == PKCE.makeChallenge(for: pair.verifier))
  }

  @Test func authorizationURLUsesTheUsersClientAndLoopbackRedirect() throws {
    let redirectURI = SpotifyAuth.redirectURI(port: 53682)
    let url = try #require(
      SpotifyAuth.configuration(clientID: "my-client").makeAuthorizationURL(
        redirectURI: redirectURI, state: "state-1",
        pair: PKCEPair(verifier: "verifier", challenge: "challenge")))
    let query = Dictionary(
      uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        ?? []).map { ($0.name, $0.value ?? "") })

    #expect(url.host == "accounts.spotify.com")
    #expect(redirectURI.absoluteString == "http://127.0.0.1:53682/callback")
    #expect(query["client_id"] == "my-client")
    #expect(query["redirect_uri"] == "http://127.0.0.1:53682/callback")
    #expect(query["response_type"] == "code")
    #expect(query["code_challenge"] == "challenge")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["state"] == "state-1")
    #expect(query["client_secret"] == nil)
    let scopes = Set((query["scope"] ?? "").split(separator: " ").map(String.init))
    #expect(scopes == Set(SpotifyAuth.scopes))
    #expect(!scopes.contains("user-read-private"))
  }

  @Test func readsTheRedirectFromTheRequestLine() {
    let url = SpotifyLoopbackReceiver.callbackURL(
      fromRequest: "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:5000\r\n\r\n",
      port: 5000, path: "/callback")
    #expect(url?.absoluteString == "http://127.0.0.1:5000/callback?code=abc&state=xyz")

    for request in [
      "GET /favicon.ico HTTP/1.1\r\n", "POST /callback?code=abc HTTP/1.1\r\n",
      "GET http://evil/callback HTTP/1.1\r\n", "",
    ] {
      #expect(
        SpotifyLoopbackReceiver.callbackURL(fromRequest: request, port: 5000, path: "/callback")
          == nil)
    }
  }

  @Test func checksStateBeforeUsingTheCode() throws {
    let redirectURI = SpotifyAuth.redirectURI(port: 5000)
    let good = URL(string: "http://127.0.0.1:5000/callback?code=abc&state=s1")!
    #expect(try SpotifySignIn.authorizationCode(from: good, redirectURI: redirectURI, state: "s1") == "abc")

    #expect(throws: SpotifySignInError.self) {
      try SpotifySignIn.authorizationCode(from: good, redirectURI: redirectURI, state: "other")
    }
    let denied = URL(string: "http://127.0.0.1:5000/callback?error=access_denied&state=s1")!
    #expect {
      try SpotifySignIn.authorizationCode(from: denied, redirectURI: redirectURI, state: "s1")
    } throws: { error in
      (error as? SpotifySignInError)?.errorDescription == "Spotify sign-in was cancelled."
    }
  }

  @Test func loopbackReceiverAnswersTheBrowserAndReturnsTheRedirect() async throws {
    let receiver = try await SpotifyLoopbackReceiver.start(path: "/callback")
    defer { receiver.stop() }
    async let callback = receiver.waitForCallback(timeout: 10)

    let (_, notFound) = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(receiver.port)/favicon.ico")!)
    let (body, response) = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(receiver.port)/callback?code=c&state=s")!)

    #expect((notFound as? HTTPURLResponse)?.statusCode == 404)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: body, as: UTF8.self).contains("Signed in to Spotify"))
    #expect(try await callback.query == "code=c&state=s")
  }

  @Test func tokenRequestsSendTheClientIDAndNoSecret() async throws {
    let requests = RequestRecorder()
    let client = SpotifyTokenClient { request in
      requests.append(request)
      return (
        Data(
          #"{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt","scope":"user-library-read playlist-read-private"}"#
            .utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    let token = try await client.exchange(
      code: "code+1", verifier: "verifier", redirectURI: SpotifyAuth.redirectURI(port: 5000),
      clientID: "my-client")

    #expect(token == SpotifyToken(
      accessToken: "at", refreshToken: "rt", scopes: ["user-library-read", "playlist-read-private"],
      expiresIn: 3600))
    let request = try #require(requests.values.first)
    #expect(request.url == SpotifyAuth.tokenURL)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let form = formValues(request)
    #expect(form["grant_type"] == "authorization_code")
    #expect(form["client_id"] == "my-client")
    #expect(form["code"] == "code+1")
    #expect(form["code_verifier"] == "verifier")
    #expect(form["redirect_uri"] == "http://127.0.0.1:5000/callback")
  }

  @Test func mapsTokenErrors() {
    func error(_ status: Int, _ json: String) -> SpotifyAPIError? {
      do {
        _ = try SpotifyTokenClient.parse(data: Data(json.utf8), statusCode: status)
        return nil
      } catch {
        return error as? SpotifyAPIError
      }
    }
    #expect(error(400, #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#) == .reconnectRequired)
    #expect(error(400, #"{"error":"invalid_client","error_description":"Invalid client"}"#) == .invalidClientID)
    #expect(error(429, "{}") == .rateLimited)
    #expect(error(500, #"{"error":"server_error"}"#) == .unexpectedStatus(500, "server_error"))
    #expect(error(200, "{}") == .invalidResponse)
  }

  @Test func keepsFreshTokensWithoutRefreshing() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let storage = MemoryStorage(session: session(expiresAt: now.addingTimeInterval(600)))
    let manager = SpotifyTokenManager(
      storage: storage.storage, tokenClient: SpotifyTokenClient { _ in throw URLError(.badURL) },
      now: { now })

    #expect(try await manager.session().accessToken == "old-access")
    #expect(SpotifyTokenManager.needsRefresh(expiresAt: now.addingTimeInterval(30), now: now))
    #expect(!SpotifyTokenManager.needsRefresh(expiresAt: nil, now: now))
  }

  @Test func refreshesExpiredTokensLocally() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let storage = MemoryStorage(session: session(expiresAt: now.addingTimeInterval(-5)))
    let requests = RequestRecorder()
    let manager = SpotifyTokenManager(
      storage: storage.storage,
      tokenClient: SpotifyTokenClient { request in
        requests.append(request)
        return (
          Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      },
      now: { now })

    let refreshed = try await manager.session()

    #expect(refreshed.accessToken == "new-access")
    // Spotify may omit a new refresh token; the old one stays good until it expires.
    #expect(refreshed.refreshToken == "old-refresh")
    #expect(refreshed.record.expiresAt == now.addingTimeInterval(3600))
    #expect(storage.current == refreshed)
    let form = formValues(try #require(requests.values.first))
    #expect(form["grant_type"] == "refresh_token")
    #expect(form["refresh_token"] == "old-refresh")
    #expect(form["client_id"] == "my-client")
  }

  @Test func expiredSignInNeedsANewSignIn() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let storage = MemoryStorage(session: session(expiresAt: now.addingTimeInterval(-5)))
    let manager = SpotifyTokenManager(
      storage: storage.storage,
      tokenClient: SpotifyTokenClient { request in
        (
          Data(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        )
      },
      now: { now })

    await #expect(throws: SpotifyAPIError.reconnectRequired) { try await manager.session() }
    #expect(storage.current == nil)
    await #expect(throws: SpotifyAPIError.missingConnection) { try await manager.session() }
  }

  @Test func needsAClientIDBeforeAnything() async {
    let storage = MemoryStorage(session: session(expiresAt: nil), clientID: nil)
    let manager = SpotifyTokenManager(storage: storage.storage)
    await #expect(throws: SpotifyAPIError.missingClientID) { try await manager.session() }
  }

  @Test func recordsKeyOnAccountIDAndTheirClient() throws {
    let profile = try #require(
      SpotifyProfile(["id": "user-1", "display_name": "Ada", "account_id": "acct-1"]))
    let now = Date(timeIntervalSince1970: 1_000)
    let record = SpotifySignIn.makeRecord(
      clientID: "my-client",
      token: SpotifyToken(accessToken: "a", refreshToken: "r", scopes: [], expiresIn: 3600),
      profile: profile, now: now)

    #expect(record.id == "acct-1")
    #expect(record.userID == "user-1")
    #expect(record.displayName == "Ada")
    #expect(record.workspaceID == "my-client")
    #expect(record.expiresAt == now.addingTimeInterval(3600))
    #expect(record.scopes == SpotifyAuth.scopes)

    let legacy = ExtensionConnectionRecord(id: "old", providerIdentifier: "spotify", displayName: "Old")
    #expect(SpotifyAuth.record(for: "my-client", in: [legacy, record]) == record)
    #expect(SpotifyAuth.record(for: "other-client", in: [legacy, record]) == nil)
    #expect(SpotifyProfile(["display_name": "No ID"]) == nil)
  }

  @MainActor
  @Test func declaresTheClientIDSettingAndNoBrokeredConnection() throws {
    let instance = try SpotifyExtension(bundle: Bundle(for: SpotifyExtension.self))
    let declaration = try #require(instance.declaration)
    try declaration.validate()
    #expect(declaration.settings.map(\.key) == [SpotifyAuth.clientIDSettingKey])
    #expect(instance.connectionDefinitions.isEmpty)
    #expect(SpotifyAuth.clientIDSetting.description?.contains(SpotifyAuth.registeredRedirectURI) == true)
  }

  // MARK: Helpers

  private func resetOverrides() {
    SpotifyAppleScript.runOverride = nil
    SpotifyAppleScript.isInstalledOverride = nil
    SpotifyAppleScript.isSpotifyRunningOverride = nil
  }

  private func session(expiresAt: Date?) -> SpotifySession {
    SpotifySession(
      record: ExtensionConnectionRecord(
        id: "acct-1", providerIdentifier: "spotify", displayName: "Ada", userID: "user-1",
        workspaceID: "my-client", expiresAt: expiresAt),
      accessToken: "old-access",
      refreshToken: "old-refresh"
    )
  }

  private func formValues(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }
}

private final class ScriptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var scripts: [String] = []
  var values: [String] { lock.withLock { scripts } }
  func append(_ script: String) { lock.withLock { scripts.append(script) } }
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [URLRequest] = []
  var values: [URLRequest] { lock.withLock { requests } }
  func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private final class MemoryStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var session: SpotifySession?
  private let clientID: String?

  init(session: SpotifySession?, clientID: String? = "my-client") {
    self.session = session
    self.clientID = clientID
  }

  var current: SpotifySession? { lock.withLock { session } }

  var storage: SpotifySessionStorage {
    SpotifySessionStorage(
      clientID: { self.clientID },
      load: { clientID in self.lock.withLock { self.session?.clientID == clientID ? self.session : nil } },
      save: { session in self.lock.withLock { self.session = session } },
      deleteAll: { self.lock.withLock { self.session = nil } }
    )
  }
}
