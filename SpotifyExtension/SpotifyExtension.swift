import Foundation
import TunaKit

@objc(SpotifyExtension)
public final class SpotifyExtension: Extension {
  static let libraryCatalogIdentifier = "spotify.library"
  static let playlistsCatalogIdentifier = "spotify.playlists"
  static let devicesCatalogIdentifier = "spotify.devices"
  static let actionsCatalogIdentifier = "spotify.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Spotify",
        author: "Tuna",
        description: "Control Spotify, browse your library, and search Spotify.",
        iconName: "music.note"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.95", minTunaKit: "1.21.0"),
      settings: [SpotifyAuth.clientIDSetting],
      catalogs: [
        CatalogDeclaration(
          id: "spotify.controls", type: SpotifyControlsCatalog.self, name: "Spotify Controls",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: Self.libraryCatalogIdentifier, type: SpotifyLibraryCatalog.self,
          name: "Spotify Library",
          presentation: .source, enabledByDefault: true),
        CatalogDeclaration(
          id: "spotify.search", type: SpotifySearchCatalog.self, name: "Spotify",
          presentation: .liveSearch, enabledByDefault: true),
        CatalogDeclaration(
          id: Self.playlistsCatalogIdentifier, type: SpotifyPlaylistsCatalog.self,
          name: "Spotify Playlists",
          presentation: .source, enabledByDefault: false),
        CatalogDeclaration(
          id: Self.devicesCatalogIdentifier, type: SpotifyDevicesCatalog.self,
          name: "Spotify Devices",
          presentation: .source, enabledByDefault: false),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier, type: SpotifyActionsCatalog.self,
          name: "Spotify Actions")
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .spotifyTrack, displayName: "Spotify Tracks", inheritsFrom: [.url]),
        TypeRegistrationDefinition(
          typeID: .spotifyAlbum, displayName: "Spotify Albums", inheritsFrom: [.url]),
        TypeRegistrationDefinition(
          typeID: .spotifyArtist, displayName: "Spotify Artists", inheritsFrom: [.url]),
        TypeRegistrationDefinition(
          typeID: .spotifyPlaylist, displayName: "Spotify Playlists", inheritsFrom: [.url]),
        TypeRegistrationDefinition(
          typeID: .spotifyDevice, displayName: "Spotify Devices", inheritsFrom: [.entity]),
      ],
      defaultActionRankings: [
        Self.ranking(
          .spotifyTrack,
          [
            "play", "save", "remove-from-library", "add-to-playlist", "add-to-queue",
            "transfer-playback", "open-in-spotify",
          ]),
        Self.ranking(
          .spotifyAlbum,
          ["play", "save", "remove-from-library", "add-to-playlist", "open-in-spotify"]),
        Self.ranking(.spotifyArtist, ["play", "open-in-spotify"]),
        Self.ranking(.spotifyPlaylist, ["play", "open-in-spotify"]),
      ],
      appBrowseEnrichments: [
        AppBrowseEnrichmentDefinition(
          bundleIdentifiers: [SpotifyAppleScript.bundleIdentifier],
          entries: [
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "spotify.controls", title: "Now Playing & Controls"),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: Self.libraryCatalogIdentifier, title: "Your Library"),
            AppBrowseEnrichmentEntryDefinition(
              catalogIdentifier: "spotify.search", title: "Search Spotify"),
          ]
        )
      ],
      appActionEnrichments: [
        AppActionEnrichmentDefinition(
          bundleIdentifiers: [SpotifyAppleScript.bundleIdentifier],
          catalogIdentifiers: [Self.actionsCatalogIdentifier]
        )
      ]
    )
  }

  private static func ranking(_ typeID: TypeID, _ actionIDs: [String])
    -> DefaultActionRankingDefinition
  {
    DefaultActionRankingDefinition(
      typeID: typeID,
      actions: actionIDs.map {
        ActionReference(catalogIdentifier: actionsCatalogIdentifier, actionID: $0)
      }
    )
  }
}
