import AppKit
import Foundation
import TunaKit

enum SpotifyCatalogSupport {
  static func loadingItem(_ title: String = "Spotify") -> CatalogLoadingItem {
    CatalogLoadingItem(title: "Loading \(title)", message: "Asking Spotify.")
  }

  static func emptyItem(_ title: String, _ message: String) -> CatalogMessageItem {
    CatalogMessageItem(
      title: title, message: message, symbolName: "tray", tintColor: .secondaryLabelColor)
  }

  static func messageItem(for error: Error) -> CatalogItem {
    if let apiError = error as? SpotifyAPIError, apiError.needsAccountSetup {
      return apiError == .missingClientID ? setupItem() : signInItem(apiError)
    }
    let apiError = error as? SpotifyAPIError
    return CatalogMessageItem(
      title: apiError?.title ?? "Spotify Unavailable",
      message: error.localizedDescription,
      symbolName: "exclamationmark.triangle",
      tintColor: .systemOrange
    )
  }

  /// What a Web API root shows instead of content when the account isn't ready, or nil when it is.
  static func accountItem() -> CatalogItem? {
    switch SpotifyAuth.state() {
    case .needsClientID: return setupItem()
    case .needsSignIn: return signInItem(.missingConnection)
    case .signedIn: return nil
    }
  }

  /// Account commands for global search: offer sign-in once a client ID is set, sign-out after.
  static func accountCommands() -> [CatalogItem] {
    switch SpotifyAuth.state() {
    case .needsClientID: return []
    case .needsSignIn: return [signInItem(.missingConnection)]
    case .signedIn(let record): return [signOutItem(record)]
    }
  }

  /// Calls `handler` after sign-in or sign-out, so catalogs drop what they showed before.
  @MainActor
  static func observeAccount(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: SpotifyAuth.accountDidChange, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { handler() }
    }
  }

  static func setupItem() -> CatalogItem {
    CommandItem(
      id: "spotify.set-up-web-api",
      title: SpotifyAPIError.missingClientID.title,
      symbol: "key",
      detail: "Search and Your Library need your own Spotify app. Opens the setup guide.",
      tintColor: .systemGreen,
      headlessEligibility: .guaranteed,
      executionPolicy: .dismiss
    ) {
      NSWorkspace.shared.open(SpotifyAuth.setupGuideURL)
      return .success
    }
  }

  static func signInItem(_ reason: SpotifyAPIError) -> CatalogItem {
    CommandItem(
      id: "spotify.sign-in",
      title: reason == .reconnectRequired ? reason.title : "Sign In to Spotify",
      symbol: "person.crop.circle.badge.plus",
      detail: reason.errorDescription,
      tintColor: .systemGreen,
      headlessEligibility: .guaranteed,
      executionPolicy: .dismiss
    ) {
      SpotifySignIn.start()
    }
  }

  static func signOutItem(_ record: ExtensionConnectionRecord) -> CatalogItem {
    CommandItem(
      id: "spotify.sign-out",
      title: "Sign Out of Spotify",
      symbol: "person.crop.circle.badge.minus",
      detail: "Signed in as \(record.trimmedDisplayName)",
      tintColor: .systemGreen,
      headlessEligibility: .guaranteed,
      executionPolicy: .dismiss
    ) {
      SpotifyAuth.signOut()
      return .success
    }
  }
}
