import AppKit
import Foundation
import TunaKit

/// Finding and copying run inline. A `.background` task was tried: its Shelf window opened for every
/// copy, and matches listed there couldn't be acted on, so a notice reports outcomes instead.
@MainActor
enum StrongboxRuntime {
  static let client = StrongboxClient()
  private static var busy = false
  private static let vaultPreference = "com.brnbw.tuna.plugins.strongbox.preferred-vault"

  private static func preferredDatabase(in databases: [StrongboxDatabase]) -> StrongboxDatabase? {
    StrongboxDatabase.selectedForSearch(
      databases, preferredID: UserDefaults.standard.string(forKey: vaultPreference))
  }

  private static func remember(_ database: StrongboxDatabase) {
    UserDefaults.standard.set(database.id, forKey: vaultPreference)
  }

  private static func chooseDatabase(_ database: StrongboxDatabase, query: String, field: StrongboxField)
    -> CatalogItem
  {
    StrongboxCommand(
      id: "strongbox.select." + database.id, title: "Use \(database.name)",
      detail: "Remember this vault for Strongbox searches; Strongbox asks for access when needed."
    ) {
      remember(database)
      return await find(query, field: field)
    }
  }

  /// Tuna closes the launcher on `.failure` and only logs the text, so the notice shows it too.
  /// A result row would leave the next Cmd-Space inside that list, where every search finds nothing.
  private static func failed(_ error: Error) -> ActionResult {
    if error is CancellationError { return .cancelled }
    return failed(safeError(error))
  }

  private static func failed(_ text: String) -> ActionResult {
    CopyNotice.show(text, for: .seconds(5))
    return .failure(text)
  }

  static func message(_ title: String, _ text: String) -> CatalogItem {
    CatalogMessageItem(
      title: title, message: text, symbolName: "lock.shield", tintColor: .secondaryLabelColor)
  }

  nonisolated static func safeError(_ error: Error) -> String {
    (error as? StrongboxError)?.errorDescription
      ?? "The Strongbox request could not be completed. No response contents were logged."
  }

  /// Vault names only, and only with several vaults. Failures stay quiet here, because a search reports them.
  /// The vault in use comes first, because Tuna selects the first row and Enter shouldn't switch vaults by accident.
  static func vaultRows() async -> [CatalogItem] {
    guard let databases = try? await client.databases(), databases.count > 1 else { return [] }
    let current = preferredDatabase(in: databases)?.id
    return (databases.filter { $0.id == current } + databases.filter { $0.id != current }).map {
      database in
      StrongboxCommand(
        id: "strongbox.select." + database.id, title: "Use \(database.name)",
        detail: database.id == current ? "The vault searched now." : "Search this vault from now on.",
        executionPolicy: .keepVisible
      ) {
        remember(database)
        CopyNotice.show("Searching \(database.name) from now on.")
        return .success
      }
    }
  }

  /// A fingerprint prompt hides the launcher, and a list that arrives afterwards waits for the next Cmd-Space.
  /// TunaKit has no call for this, so `tuna://search` brings it back. It shows only the first match,
  /// so the notice says there are more.
  private static func showLauncher(matches: Int) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      if let url = URL(string: "tuna://search") { await URIOpener.openOnMainActor(url) }
      CopyNotice.show("\(matches) matches. Press Down to see them.", for: .seconds(4))
    }
  }

  /// Runs on every keystroke, so typing must not contact Strongbox. Only an empty query reads vault names.
  static func queryItems(_ query: String, first: StrongboxField) async -> [CatalogItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query.count >= 2 else {
      let hint = message("Keep typing", "Type at least two characters, then press Enter.")
      return query.isEmpty ? [hint] + (await vaultRows()) : [hint]
    }
    return ([first] + StrongboxField.allCases.filter { $0 != first }).map {
      StrongboxQueryItem(query, field: $0)
    }
  }

  static func find(_ query: String, field: StrongboxField) async -> ActionResult {
    guard !busy else { return failed(safeError(StrongboxError.busy)) }
    busy = true
    defer { busy = false }
    let launcher = NSApp.keyWindow
    do {
      let databases = try await client.databases()
      guard !databases.isEmpty else {
        return failed("No opted-in vaults. Enable a vault for MCP in Strongbox first.")
      }
      guard let database = preferredDatabase(in: databases) else {
        // Tuna selects the first row, and Enter on the explanation would offer its generic actions.
        return .results(
          databases.map { chooseDatabase($0, query: query, field: field) }
            + [message("Choose a vault", "Your search will run after selecting a vault; the choice is remembered.")])
      }
      remember(database)
      let entries = try await client.search(query, databaseID: database.id)
      if let entry = StrongboxEntry.directMatch(in: entries, query: query) {
        return await performCopy(field, of: entry)
      }
      guard !entries.isEmpty else { return failed("No matching entries in \(database.name).") }
      if launcher?.isVisible != true { showLauncher(matches: entries.count) }
      return .results(entries.map { StrongboxEntryItem($0, field: field) })
    } catch {
      return failed(error)
    }
  }

  static func copy(_ field: StrongboxField, of entry: StrongboxEntry) async -> ActionResult {
    guard !busy else { return failed(safeError(StrongboxError.busy)) }
    busy = true
    defer { busy = false }
    return await performCopy(field, of: entry)
  }

  private static func performCopy(_ field: StrongboxField, of entry: StrongboxEntry) async
    -> ActionResult
  {
    do {
      let value = try await client.value(of: field, in: entry)
      try Task.checkCancellation()
      guard ConcealedClipboard().write(value, clearAfter: StrongboxClient.pasteWindow) else {
        return failed(safeError(StrongboxError.clipboardWriteFailed))
      }
      CopyNotice.show("Copied \(field.label) for \(entry.title)")
      return .success
    } catch {
      return failed(error)
    }
  }
}

/// TunaKit has no toast API, and the launcher closes after a copy or failure, so this says what happened.
@MainActor
private enum CopyNotice {
  private static var panel: NSPanel?

  static func show(_ text: String, for duration: Duration = .seconds(2)) {
    panel?.orderOut(nil)
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.preferredMaxLayoutWidth = 480
    label.frame.size = label.fittingSize
    let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 24)
    label.frame.origin = NSPoint(x: 20, y: 12)
    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .hudWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.addSubview(label)
    let notice = NSPanel(
      contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    notice.isOpaque = false
    notice.backgroundColor = .clear
    notice.level = .statusBar
    notice.ignoresMouseEvents = true
    notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    notice.contentView = background
    if let screen = NSScreen.main?.visibleFrame {
      notice.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 96))
    }
    notice.orderFrontRegardless()
    panel = notice
    Task { @MainActor in
      try? await Task.sleep(for: duration)
      notice.orderOut(nil)
      if panel === notice { panel = nil }
    }
  }
}
