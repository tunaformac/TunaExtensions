import AppKit
import Foundation

/// A create is handed to Fantastical over the URL scheme, so it lands when Fantastical writes it:
/// at once when it is told to add silently, only after the user's Enter when the parse preview is
/// shown. The agenda is dropped now and again when the user comes back from Fantastical.
@MainActor
final class FantasticalCreateWatcher {
  static let shared = FantasticalCreateWatcher()
  static let fallbackSeconds = 30

  private var observer: NSObjectProtocol?
  private var fallback: Task<Void, Never>?

  func creationStarted() {
    FantasticalAgendaSupport.postDataDidChange()
    guard observer == nil else { return }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      guard app?.bundleIdentifier != FantasticalIdentifiers.bundleIdentifier else { return }
      Task { @MainActor in self?.settled() }
    }
    fallback = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.fallbackSeconds))
      guard !Task.isCancelled else { return }
      self?.settled()
    }
  }

  private func settled() {
    guard let observer else { return }
    NSWorkspace.shared.notificationCenter.removeObserver(observer)
    self.observer = nil
    fallback?.cancel()
    fallback = nil
    FantasticalAgendaSupport.postDataDidChange()
  }
}
