import Foundation
import TunaKit
import XCTest

@testable import TunaMusic

final class MusicExtensionTests: XCTestCase {
  private let RS = MusicLibraryDump.recordSeparator
  private let GS = MusicLibraryDump.groupSeparator
  private let FS = MusicLibraryDump.sectionSeparator

  override func tearDown() {
    MusicAppleScript.runOverride = nil
    MusicAppleScript.isMusicRunningOverride = nil
    super.tearDown()
  }

  // MARK: Fixtures

  private func column(_ values: [String]) -> String { values.joined(separator: RS) }

  /// Two albums by one artist plus a single by another, and two playlists.
  private var fixtureDump: String {
    let tracks = [
      column(["Second Song", "First Song", "Only Song", "Untitled"]),
      column(["Band", "Band", "Solo", "Nobody"]),
      column(["Band", "Band", "", ""]),
      column(["Debut", "Debut", "Single", ""]),
      column(["2", "1", "1", "0"]),
      column(["1", "1", "1", "0"]),
      column(["2001", "2001", "2020", "0"]),
      column(["200,5", "180.25", "90", "0"]),
      column(["true", "false", "false", "false"]),
      column(["AAA", "BBB", "CCC", "DDD"]),
    ].joined(separator: GS)
    let playlists = [
      ["Road Trip", "PL1", "false", "BBB,AAA,missing"].joined(separator: RS),
      ["Favourites", "PL2", "true", ""].joined(separator: RS),
    ].joined(separator: GS) + GS
    return tracks + FS + playlists
  }

  // MARK: Declaration

  @MainActor
  func testDeclarationValidatesAndDeclaresLibraryBrowseAndSearch() throws {
    let instance = try MusicExtension(bundle: Bundle(for: MusicExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(
      declaration.catalogs.map(\.id),
      [
        "music.controls", "music.songs", "music.songs.search", "music.albums", "music.albums.search",
        "music.artists", "music.artists.search", "music.playlists", "music.playlists.search", "music.search",
      ]
    )
    for section in ["songs", "albums", "artists", "playlists"] {
      XCTAssertEqual(
        declaration.catalogs.first { $0.id == "music.\(section).search" }?.presentation,
        .browseRoot(contents: "music.\(section)"),
        "\(section) content stays out of global search behind its browse root"
      )
    }
    let browseEntries = declaration.appBrowseEnrichments.first?.entries.map(\.catalogIdentifier) ?? []
    XCTAssertFalse(browseEntries.contains("music.albums"), "app browse should point at browse roots")
    XCTAssertTrue(browseEntries.contains("music.albums.search"))
    XCTAssertEqual(declaration.catalogs.first { $0.id == "music.search" }?.presentation, .liveSearch)
    XCTAssertTrue(declaration.catalogs.allSatisfy(\.enabledByDefault))
    XCTAssertEqual(declaration.appBrowseEnrichments.first?.bundleIdentifiers, ["com.apple.Music"])

    let actionIDs = Set(MusicActionsCatalog.makeActions().map(\.id))
    for ranking in declaration.defaultActionRankings {
      for reference in ranking.actions {
        XCTAssertEqual(reference.catalogIdentifier, "music.actions")
        XCTAssertTrue(actionIDs.contains(reference.actionID), reference.actionID)
      }
    }
  }

  // MARK: Parsing and grouping

  func testDumpParsesTracksAndPlaylistsIncludingLocaleDecimals() throws {
    let snapshot = try MusicLibraryDump.parse(fixtureDump)

    XCTAssertEqual(snapshot.tracks.count, 4)
    let first = try XCTUnwrap(snapshot.tracks.first)
    XCTAssertEqual(first.persistentID, "AAA")
    XCTAssertEqual(first.title, "Second Song")
    XCTAssertEqual(first.duration, 200.5)
    XCTAssertTrue(first.isFavorited)
    XCTAssertEqual(snapshot.tracks[1].duration, 180.25)
    XCTAssertEqual(snapshot.tracks[3].album, "")

    XCTAssertEqual(snapshot.playlists.map(\.name), ["Road Trip", "Favourites"])
    XCTAssertEqual(snapshot.playlists[0].trackPersistentIDs, ["BBB", "AAA", "missing"])
    XCTAssertFalse(snapshot.playlists[0].isSmart)
    XCTAssertTrue(snapshot.playlists[1].isSmart)
    XCTAssertEqual(snapshot.playlists[1].trackPersistentIDs, [])
    XCTAssertEqual(snapshot.tracks(withPersistentIDs: snapshot.playlists[0].trackPersistentIDs).map(\.persistentID), ["BBB", "AAA"])
  }

  func testDumpRejectsMismatchedColumns() {
    let broken = column(["a", "b"]) + GS + Array(repeating: column(["x"]), count: 9).joined(separator: GS) + FS
    XCTAssertThrowsError(try MusicLibraryDump.parse(broken))
    XCTAssertThrowsError(try MusicLibraryDump.parse("no sections"))
  }

  func testEmptyLibraryParsesToNoTracks() throws {
    let empty = Array(repeating: "", count: 10).joined(separator: GS) + FS
    XCTAssertEqual(try MusicLibraryDump.parse(empty).tracks.count, 0)
  }

  func testAlbumsGroupByAlbumArtistWithTracksInOrderAndSkipUntitled() throws {
    let albums = try MusicLibraryDump.parse(fixtureDump).albums()

    XCTAssertEqual(albums.map(\.title), ["Debut", "Single"])
    XCTAssertEqual(albums[0].artist, "Band")
    XCTAssertEqual(albums[0].year, 2001)
    XCTAssertEqual(albums[0].tracks.map(\.title), ["First Song", "Second Song"])
    XCTAssertEqual(albums[1].artist, "Solo")
  }

  func testArtistsGroupAlbums() throws {
    let artists = try MusicLibraryDump.parse(fixtureDump).artists()
    XCTAssertEqual(artists.map(\.name), ["Band", "Solo"])
    XCTAssertEqual(artists[0].albums.map(\.title), ["Debut"])
  }

  // MARK: Store

  @MainActor
  func testStoreReadsLiveLibraryAndFallsBackToCacheWhenMusicIsClosed() async throws {
    let cacheURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("library.json")
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let dump = fixtureDump
    MusicAppleScript.isMusicRunningOverride = { true }
    MusicAppleScript.runOverride = { _ in dump }

    let store = MusicLibraryStore(cacheURL: cacheURL)
    let live = await store.load()
    XCTAssertEqual(live.source, .live)
    XCTAssertEqual(live.snapshot?.tracks.count, 4)

    MusicAppleScript.isMusicRunningOverride = { false }
    store.invalidate()
    let cached = await store.load()
    XCTAssertEqual(cached.source, .cached)
    XCTAssertEqual(cached.snapshot?.playlists.count, 2)

    let unavailable = MusicLibraryStore.performLoad(cacheURL: cacheURL.appendingPathExtension("missing"))
    XCTAssertEqual(unavailable.source, .unavailable)
    XCTAssertNil(unavailable.snapshot)
  }

  @MainActor
  func testStoreKeepsCacheWhenTheDumpFails() async throws {
    let cacheURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("library.json")
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let dump = fixtureDump
    MusicAppleScript.isMusicRunningOverride = { true }
    MusicAppleScript.runOverride = { _ in dump }
    let store = MusicLibraryStore(cacheURL: cacheURL)
    _ = await store.load()

    MusicAppleScript.runOverride = { _ in throw MusicScriptError.automationDenied }
    store.invalidate()
    let load = await store.load()
    XCTAssertEqual(load.source, .cached)
    XCTAssertEqual(load.errorMessage, MusicScriptError.automationDenied.errorDescription)
  }

  // MARK: Catalog shape

  @MainActor
  func testLibraryCatalogsBuildTypedItemsAndBrowseHierarchy() throws {
    let snapshot = try MusicLibraryDump.parse(fixtureDump)
    let load = MusicLibraryStore.Load(snapshot: snapshot, source: .live, errorMessage: nil)

    let songs = MusicLibraryCatalogBase.buildItems(for: .songs, mode: .all, load: load)
    XCTAssertEqual(songs.map(\.title), ["First Song", "Only Song", "Second Song", "Untitled"])
    XCTAssertEqual(songs.first?.id, "music.song.BBB")
    XCTAssertEqual(songs.first?.typeID, .musicSong)
    XCTAssertEqual(songs.first?.searchText, "First Song Band Debut")
    XCTAssertEqual((songs.first as? TextValueProviding)?.textValue, "First Song — Band")

    let albums = MusicLibraryCatalogBase.buildItems(for: .albums, mode: .all, load: load)
    let debut = try XCTUnwrap(albums.first as? MusicAlbumItem)
    XCTAssertEqual(debut.typeID, .musicAlbum)
    XCTAssertEqual(debut.detail, "Band · 2001 · 2 songs")
    XCTAssertEqual(debut.hierarchyChildren().map(\.title), ["First Song", "Second Song"])
    XCTAssertEqual(debut.trackIDs, ["BBB", "AAA"])

    let artists = MusicLibraryCatalogBase.buildItems(for: .artists, mode: .all, load: load)
    let band = try XCTUnwrap(artists.first as? MusicArtistItem)
    XCTAssertEqual(band.typeID, .musicArtist)
    XCTAssertEqual(band.hierarchyChildren().map(\.title), ["Debut"])

    let playlists = MusicLibraryCatalogBase.buildItems(for: .playlists, mode: .all, load: load)
    let roadTrip = try XCTUnwrap(playlists.first as? MusicPlaylistItem)
    XCTAssertEqual(roadTrip.id, "music.playlist.PL1")
    XCTAssertEqual(roadTrip.detail, "2 songs")
    XCTAssertEqual(roadTrip.hierarchyChildren().map(\.title), ["First Song", "Second Song"])
    let smart = try XCTUnwrap(playlists.last as? MusicPlaylistItem)
    XCTAssertEqual(smart.detail, "0 songs · Smart Playlist")
    XCTAssertTrue(smart.hierarchyChildren().first is CatalogMessageItem)
  }

  @MainActor
  func testUnavailableLibraryLeavesSourcesEmptyAndExplainsInBrowseRoot() {
    let closed = MusicLibraryStore.Load(snapshot: nil, source: .unavailable, errorMessage: nil)
    XCTAssertTrue(MusicLibraryCatalogBase.buildItems(for: .songs, mode: .all, load: closed).isEmpty)
    XCTAssertTrue(MusicLibraryCatalogBase.buildItems(for: .albums, mode: .all, load: closed).isEmpty)
    XCTAssertEqual(MusicLibraryCatalogBase.buildItems(for: .albums, mode: .browse, load: closed).first?.title, "Music Isn’t Running")

    let denied = MusicLibraryStore.Load(snapshot: nil, source: .unavailable, errorMessage: "denied")
    XCTAssertEqual(MusicLibraryCatalogBase.buildItems(for: .songs, mode: .browse, load: denied).first?.title, "Couldn’t Read Music Library")

    let empty = MusicLibraryStore.Load(snapshot: MusicLibrarySnapshot(tracks: [], playlists: [], capturedAt: Date()), source: .live, errorMessage: nil)
    XCTAssertEqual(MusicLibraryCatalogBase.buildItems(for: .playlists, mode: .browse, load: empty).first?.title, "No Playlists")
    XCTAssertTrue(MusicLibraryCatalogBase.buildItems(for: .playlists, mode: .all, load: empty).isEmpty)
  }

  @MainActor
  func testBrowseCatalogsExposeASingleBrowseRootEach() {
    let definition = CatalogDefinition(identifier: "music.x.search", name: "X", enabledByDefault: true, settings: [])
    let roots: [(MusicLibraryCatalogBase, String)] = [
      (MusicSongsBrowseCatalog(definition: definition), "music.songs"),
      (MusicAlbumsBrowseCatalog(definition: definition), "music.albums"),
      (MusicArtistsBrowseCatalog(definition: definition), "music.artists"),
      (MusicPlaylistsBrowseCatalog(definition: definition), "music.playlists"),
    ]
    for (catalog, rootID) in roots {
      XCTAssertEqual(catalog.objects.count, 1)
      let root = catalog.objects.first as? BrowseCatalogItem
      XCTAssertEqual(root?.id, rootID)
      XCTAssertTrue(root?.hierarchyChildren().first is CatalogLoadingItem)
    }
  }

  @MainActor
  func testControlsCatalogListsTransportCommands() {
    let catalog = MusicControlsCatalog(
      definition: CatalogDefinition(identifier: "music.controls", name: "Music Controls", enabledByDefault: true, settings: [])
    )
    XCTAssertEqual(
      catalog.objects.map(\.id),
      ["play-pause", "next-track", "previous-track", "toggle-shuffle", "toggle-repeat"]
    )
    XCTAssertTrue(catalog.objects.allSatisfy { $0 is CommandItem })
  }

  @MainActor
  func testAppleMusicCatalogExposesAScopedSearchRoot() {
    let catalog = AppleMusicCatalog(
      definition: CatalogDefinition(identifier: "music.search", name: "Apple Music", enabledByDefault: true, settings: [])
    )
    XCTAssertTrue(catalog.objects.first is ScopedSearchBrowseCatalogItem)
    let entry = AppleMusicEntry(kind: .station, id: "st.1", title: "Chill", subtitle: "Station", url: URL(string: "https://music.apple.com/station"), artwork: nil)
    let item = AppleMusicItem(entry: entry)
    XCTAssertEqual(item.id, "music.catalog.station.st.1")
    XCTAssertEqual(item.typeID, .musicStation)
  }

  // MARK: Now Playing

  func testNowPlayingParsesStatesAndIgnoresStopped() {
    let paused = ["paused", "PID", "Song", "Artist", "Album", "true"].joined(separator: RS)
    XCTAssertEqual(
      MusicAppleScript.parseNowPlaying(paused),
      MusicNowPlaying(state: .paused, persistentID: "PID", title: "Song", artist: "Artist", album: "Album", isFavorited: true)
    )
    XCTAssertEqual(MusicAppleScript.parseNowPlaying(["fast forwarding", "P", "S", "A", "L", "false"].joined(separator: RS))?.state, .playing)
    XCTAssertNil(MusicAppleScript.parseNowPlaying("stopped"))
  }

  @MainActor
  func testNowPlayingItemIsASongWithTextValue() {
    let item = MusicNowPlayingItem(
      nowPlaying: MusicNowPlaying(state: .paused, persistentID: "PID", title: "Song", artist: "Artist", album: "Album", isFavorited: false))
    XCTAssertEqual(item.id, "music.now-playing")
    XCTAssertEqual(item.typeID, .musicSong)
    XCTAssertEqual(item.textValue, "Song — Artist")
    XCTAssertEqual(item.detail, "Song — Artist · Paused")
    XCTAssertEqual(MusicActions.trackIDs(of: item), ["PID"])
  }

  // MARK: Scripts

  func testScriptLiteralsEscapeQuotesAndBackslashes() {
    XCTAssertEqual(MusicAppleScript.Scripts.literal(#"Say "Hi" \ Bye"#), #""Say \"Hi\" \\ Bye""#)
    XCTAssertEqual(MusicAppleScript.Scripts.list(["A", "B"]), #"{"A", "B"}"#)
  }

  func testHelperPlaylistScriptRebuildsTheTunaPlaylist() {
    let script = MusicAppleScript.Scripts.playThroughHelperPlaylist(trackIDs: ["AAA", "BBB"], shuffle: true)
    XCTAssertTrue(script.contains(#"user playlist "Tuna""#))
    XCTAssertTrue(script.contains("delete every track of queuePlaylist"))
    XCTAssertTrue(script.contains(#"{"AAA", "BBB"}"#))
    XCTAssertTrue(script.contains("set shuffle enabled to true"))
    XCTAssertTrue(script.contains("play queuePlaylist"))
  }

  func testCommandsRouteThroughTheInjectedRunner() throws {
    let recorded = LockedValue<[String]>([])
    MusicAppleScript.runOverride = { source in
      recorded.append(source)
      return ""
    }
    try MusicAppleScript.play(trackID: "AAA")
    try MusicAppleScript.setFavorited(true, trackID: "AAA")
    try MusicAppleScript.add(trackIDs: ["AAA"], toPlaylistID: "PL1")
    let scripts = recorded.value
    XCTAssertEqual(scripts.count, 3)
    XCTAssertTrue(scripts[0].contains(#"play (first track of library playlist 1 whose persistent ID is "AAA")"#))
    XCTAssertTrue(scripts[1].contains("set favorited of (first track of library playlist 1 whose persistent ID is \"AAA\") to true"))
    XCTAssertTrue(scripts[2].contains(#"first user playlist whose persistent ID is "PL1""#))
  }

  // MARK: Action grammar

  @MainActor
  func testActionGrammarMatchesTheDesign() throws {
    let actions = MusicActionsCatalog.makeActions()
    let byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    let track = MusicTrack(persistentID: "AAA", title: "Song", artist: "Band", albumArtist: "Band", album: "Debut", trackNumber: 1, discNumber: 1, year: 2001, duration: 1, isFavorited: false)
    let song = MusicSongItem(track: track)
    let favorited = MusicSongItem(track: MusicTrack(persistentID: "BBB", title: "Loved", artist: "Band", albumArtist: "Band", album: "Debut", trackNumber: 2, discNumber: 1, year: 2001, duration: 1, isFavorited: true))
    let regular = MusicPlaylistItem(playlist: MusicPlaylist(persistentID: "PL1", name: "Road Trip", isSmart: false, trackPersistentIDs: []), tracks: [])
    let smart = MusicPlaylistItem(playlist: MusicPlaylist(persistentID: "PL2", name: "Favourites", isSmart: true, trackPersistentIDs: []), tracks: [])
    let catalogSong = AppleMusicItem(entry: AppleMusicEntry(kind: .song, id: "1", title: "Remote", subtitle: nil, url: URL(string: "https://music.apple.com/x"), artwork: nil))

    let play = try XCTUnwrap(byID["play"] as? PredicateAwareAction)
    XCTAssertEqual(play.targetRequirement, .none)
    XCTAssertEqual(play.supportedSubjectTypes, [.musicSong, .musicAlbum, .musicArtist, .musicPlaylist])
    XCTAssertTrue(play.subjectPredicate?(song) == true)
    XCTAssertTrue(play.subjectPredicate?(catalogSong) == false)

    let shuffle = try XCTUnwrap(byID["shuffle"] as? PredicateAwareAction)
    XCTAssertTrue(shuffle.subjectPredicate?(regular) == true)
    XCTAssertTrue(shuffle.subjectPredicate?(song) == false)

    let favorite = try XCTUnwrap(byID["favorite"] as? PredicateAwareAction)
    let unfavorite = try XCTUnwrap(byID["unfavorite"] as? PredicateAwareAction)
    XCTAssertTrue(favorite.subjectPredicate?(song) == true)
    XCTAssertTrue(favorite.subjectPredicate?(favorited) == false)
    XCTAssertTrue(unfavorite.subjectPredicate?(favorited) == true)
    XCTAssertTrue(unfavorite.subjectPredicate?(catalogSong) == false)

    let addToPlaylist = try XCTUnwrap(byID["add-to-playlist"] as? PredicateAwareAction)
    XCTAssertEqual(addToPlaylist.targetRequirement, .required)
    XCTAssertEqual(addToPlaylist.allowedTargetTypes, [.musicPlaylist])
    XCTAssertEqual(addToPlaylist.targetSearchScope, .catalogs(["music.playlists"], preparation: .refresh))
    XCTAssertNotNil(addToPlaylist.batchCallback)
    XCTAssertTrue(addToPlaylist.targetPredicate?(regular) == true)
    XCTAssertTrue(addToPlaylist.targetPredicate?(smart) == false)
    XCTAssertTrue(addToPlaylist.subjectPredicate?(catalogSong) == false)

    XCTAssertNil(byID["add-to-library"], "MusicKit has no library writes on macOS")

    let openInMusic = try XCTUnwrap(byID["open-in-music"] as? PredicateAwareAction)
    XCTAssertTrue(openInMusic.subjectPredicate?(catalogSong) == true)
    XCTAssertTrue(openInMusic.subjectPredicate?(song) == false)

    XCTAssertFalse(actions.contains { $0.title.hasSuffix("…") || $0.title.hasSuffix("...") })
    for id in ["play-pause", "next-track", "previous-track"] {
      XCTAssertEqual(byID[id]?.supportedSubjectTypes, [.application], id)
    }
  }
}
