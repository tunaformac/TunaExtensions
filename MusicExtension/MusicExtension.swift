import Foundation
import TunaKit

@objc(MusicExtension)
public final class MusicExtension: Extension {
  static let playlistsCatalogIdentifier = "music.playlists"
  static let actionsCatalogIdentifier = "music.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Music",
        author: "Tuna",
        description: "Control Music, browse your library, and search Apple Music.",
        iconName: "music.note"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      catalogs: [
        CatalogDeclaration(
          id: "music.controls", type: MusicControlsCatalog.self, name: "Music Controls",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "music.songs", type: MusicSongsCatalog.self, name: "Songs",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "music.songs.search", type: MusicSongsBrowseCatalog.self, name: "Songs",
          presentation: .browseRoot(contents: "music.songs"), enabledByDefault: true),
        CatalogDeclaration(
          id: "music.albums", type: MusicAlbumsCatalog.self, name: "Albums",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "music.albums.search", type: MusicAlbumsBrowseCatalog.self, name: "Albums",
          presentation: .browseRoot(contents: "music.albums"), enabledByDefault: true),
        CatalogDeclaration(
          id: "music.artists", type: MusicArtistsCatalog.self, name: "Artists",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "music.artists.search", type: MusicArtistsBrowseCatalog.self, name: "Artists",
          presentation: .browseRoot(contents: "music.artists"), enabledByDefault: true),
        CatalogDeclaration(
          id: Self.playlistsCatalogIdentifier, type: MusicPlaylistsCatalog.self, name: "Playlists",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "music.playlists.search", type: MusicPlaylistsBrowseCatalog.self, name: "Playlists",
          presentation: .browseRoot(contents: Self.playlistsCatalogIdentifier), enabledByDefault: true),
        CatalogDeclaration(
          id: "music.search", type: AppleMusicCatalog.self, name: "Apple Music",
          presentation: .liveSearch, enabledByDefault: true),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier, type: MusicActionsCatalog.self, name: "Music Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(typeID: .musicSong, displayName: "Songs", inheritsFrom: [.entity]),
        TypeRegistrationDefinition(typeID: .musicAlbum, displayName: "Albums", inheritsFrom: [.entity]),
        TypeRegistrationDefinition(typeID: .musicArtist, displayName: "Artists", inheritsFrom: [.entity]),
        TypeRegistrationDefinition(typeID: .musicPlaylist, displayName: "Playlists", inheritsFrom: [.entity]),
        TypeRegistrationDefinition(typeID: .musicStation, displayName: "Stations", inheritsFrom: [.entity]),
      ],
      defaultActionRankings: [
        Self.ranking(.musicSong, ["play", "show-in-music", "favorite", "add-to-playlist", "open-in-music"]),
        Self.ranking(.musicAlbum, ["play", "shuffle", "show-in-music", "open-in-music"]),
        Self.ranking(.musicArtist, ["play", "shuffle", "show-in-music", "open-in-music"]),
        Self.ranking(.musicPlaylist, ["play", "shuffle", "show-in-music", "open-in-music"]),
        Self.ranking(.musicStation, ["open-in-music"]),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: [MusicAppleScript.bundleIdentifier],
          entries: [
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.controls", title: "Now Playing & Controls"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.playlists.search", title: "Playlists"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.albums.search", title: "Albums"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.artists.search", title: "Artists"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.songs.search", title: "Songs"),
            AppBrowseEnrichmentEntryDefinition(catalogIdentifier: "music.search", title: "Apple Music"),
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: [MusicAppleScript.bundleIdentifier],
          catalogIdentifiers: [Self.actionsCatalogIdentifier]
        )
      ]
    )
  }

  private static func ranking(_ typeID: TypeID, _ actionIDs: [String]) -> DefaultActionRankingDefinition {
    DefaultActionRankingDefinition(
      typeID: typeID,
      actions: actionIDs.map { ActionReference(catalogIdentifier: actionsCatalogIdentifier, actionID: $0) }
    )
  }
}
