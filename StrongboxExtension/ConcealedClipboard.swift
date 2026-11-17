import AppKit

@MainActor
final class ConcealedClipboard {
  static let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
    .map { NSPasteboard.PasteboardType($0) }

  /// The last value written, so quitting Tuna can clear it if nothing replaced it.
  private static var lastWrite: (pasteboard: NSPasteboard, changeCount: Int)?
  private static var quitObserver: NSObjectProtocol?

  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

  /// Stays on this Mac, is marked concealed and transient for clipboard managers, and is cleared after
  /// `seconds` or when Tuna quits, unless something newer replaced it. A crash still leaves it behind:
  /// a signal handler inside Tuna's process can't safely touch the pasteboard.
  func write(_ value: String, clearAfter seconds: TimeInterval) -> Bool {
    pasteboard.prepareForNewContents(with: .currentHostOnly)
    guard Self.markers.allSatisfy({ pasteboard.setString("", forType: $0) }),
       pasteboard.setString(value, forType: .string) else {
      pasteboard.clearContents()
      return false
    }
    let written = pasteboard.changeCount
    Self.clearOnQuit(pasteboard, changeCount: written)
    Task { [pasteboard] in
      try? await Task.sleep(for: .seconds(seconds))
      if pasteboard.changeCount == written { pasteboard.clearContents() }
    }
    return true
  }

  private static func clearOnQuit(_ pasteboard: NSPasteboard, changeCount: Int) {
    lastWrite = (pasteboard, changeCount)
    guard quitObserver == nil else { return }
    quitObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        if let lastWrite, lastWrite.pasteboard.changeCount == lastWrite.changeCount {
          lastWrite.pasteboard.clearContents()
        }
      }
    }
  }
}
