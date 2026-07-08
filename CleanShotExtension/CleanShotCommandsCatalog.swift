//
//  CleanShotCommandsCatalog.swift
//  CleanShotExtension
//
//  CleanShot X quick commands via URL schemes.
//

import AppKit
import Foundation
import TunaKit

public final class CleanShotCommandsCatalog: Catalog {
  public let identifier: String
  public let name: String

  private let objectsStore = LockedValue<[CatalogItem]>([])
  public var objects: [CatalogItem] {
    objectsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }

  public func scan() async {
    objectsStore.value = Self.makeCommands()
  }

  private static func makeCommands() -> [CatalogItem] {
    let commands: [CommandDefinition] = [
      CommandDefinition(
        id: "all-in-one-capture",
        title: "All-in-One Capture",
        detail: "Open CleanShot's all-in-one picker",
        symbol: "camera.viewfinder",
        command: "all-in-one"
      ),
      CommandDefinition(
        id: "capture-area",
        title: "Capture Area",
        detail: "Capture a selection",
        symbol: "rectangle.dashed",
        command: "capture-area"
      ),
      CommandDefinition(
        id: "capture-window",
        title: "Capture Window",
        detail: "Capture a window",
        symbol: "macwindow",
        command: "capture-window"
      ),
      CommandDefinition(
        id: "capture-full-screen",
        title: "Capture Full Screen",
        detail: "Capture the full screen",
        symbol: "rectangle",
        command: "capture-fullscreen"
      ),
      CommandDefinition(
        id: "capture-previous-area",
        title: "Capture Previous Area",
        detail: "Capture the last selection again",
        symbol: "arrow.clockwise",
        command: "capture-previous-area"
      ),
      CommandDefinition(
        id: "scrolling-capture",
        title: "Scrolling Capture",
        detail: "Capture a scrolling area",
        symbol: "arrow.up.and.down",
        command: "scrolling-capture"
      ),
      CommandDefinition(
        id: "self-timer-capture",
        title: "Self Timer Capture",
        detail: "Capture after a short timer",
        symbol: "timer",
        command: "self-timer"
      ),
      CommandDefinition(
        id: "record-screen",
        title: "Record Screen",
        detail: "Start screen recording",
        symbol: "record.circle",
        command: "record-screen"
      ),
      CommandDefinition(
        id: "capture-text-ocr",
        title: "Capture Text (OCR)",
        detail: "Extract text from the screen",
        symbol: "text.magnifyingglass",
        command: "capture-text"
      ),
      CommandDefinition(
        id: "open-history",
        title: "Open History",
        detail: "Show CleanShot history",
        symbol: "clock.arrow.circlepath",
        command: "open-history"
      ),
      CommandDefinition(
        id: "open-annotate",
        title: "Open Annotate",
        detail: "Open the annotate window",
        symbol: "square.and.pencil",
        command: "open-annotate"
      ),
      CommandDefinition(
        id: "annotate-from-clipboard",
        title: "Annotate from Clipboard",
        detail: "Open annotate with clipboard image",
        symbol: "doc.on.clipboard",
        command: "open-from-clipboard"
      ),
      CommandDefinition(
        id: "restore-recently-closed",
        title: "Restore Recently Closed",
        detail: "Restore the last closed capture",
        symbol: "arrow.uturn.backward",
        command: "restore-recently-closed"
      ),
      CommandDefinition(
        id: "toggle-desktop-icons",
        title: "Toggle Desktop Icons",
        detail: "Show or hide desktop icons",
        symbol: "desktopcomputer",
        command: "toggle-desktop-icons"
      ),
      CommandDefinition(
        id: "hide-desktop-icons",
        title: "Hide Desktop Icons",
        detail: "Hide desktop icons",
        symbol: "eye.slash",
        command: "hide-desktop-icons"
      ),
      CommandDefinition(
        id: "show-desktop-icons",
        title: "Show Desktop Icons",
        detail: "Show desktop icons",
        symbol: "eye",
        command: "show-desktop-icons"
      ),
      CommandDefinition(
        id: "open-settings",
        title: "Open Settings",
        detail: "Open CleanShot settings",
        symbol: "gearshape",
        command: "open-settings"
      ),
    ]

    return commands.compactMap { command in
      guard let url = command.url else { return nil }
      return CommandItem(
        id: command.id,
        title: command.title,
        symbol: command.symbol,
        detail: command.detail,
        tintColor: .systemOrange
      ) {
        guard URIOpener.open(url) else {
          return .failure("CleanShot X is not available")
        }
        return .success
      }
    }
  }
}

private struct CommandDefinition {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  let command: String

  var url: URL? {
    URL(string: "cleanshot://\(command)")
  }
}
