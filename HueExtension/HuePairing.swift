import AppKit
import SwiftUI

@MainActor
enum HuePairing {
  static func connect() async throws -> Bool {
    var manual = false
    while true {
      let result = try await (manual ? connectManually() : connectAutomatically())
      switch result {
      case .connected(let name):
        showConnectionConfirmation(for: name)
        return true
      case .cancelled: return false
      case .switchMode: manual.toggle()
      case .refresh: break
      }
    }
  }

  private enum ConnectionResult {
    case connected(String)
    case cancelled, switchMode, refresh
  }

  private static func connectAutomatically() async throws -> ConnectionResult {
    let prompt = HuePairingPrompt()
    prompt.show()
    defer {
      prompt.cancelPairing = nil
      prompt.close()
    }
    let pairing = Task { () throws -> String? in
      let connected = Set(try HueConnections.records().keys)
      let bridges = try await DiscoveredHueBridge.discover().filter {
        !connected.contains($0.id.lowercased())
      }
      try Task.checkCancellation()
      let choice = await prompt.choose(from: bridges)
      try Task.checkCancellation()
      guard let (bridge, name) = choice else { return nil }
      let id = bridge.id.lowercased()
      try HueConnections.requireNew(id)
      let address = bridge.internalipaddress
      let client = try bridge.pairingClient()
      prompt.showPairing(for: name)
      while true {
        try Task.checkCancellation()
        let key: String
        do {
          key = try await client.pair()
        } catch HueError.pairingTimedOut {
          guard await prompt.waitForRetry() else { return nil }
          continue
        }
        try Task.checkCancellation()
        prompt.showVerification()
        return try await HueConnections.add(
          address: address, id: id, key: key, path: DiscoveredHueBridge.caPath
        )
      }
    }
    prompt.cancelPairing = { pairing.cancel() }
    do {
      let name = try await pairing.value
      if prompt.refreshRequested { return .refresh }
      return name.map(ConnectionResult.connected) ?? .cancelled
    } catch {
      if prompt.manual { return .switchMode }
      if prompt.refreshRequested { return .refresh }
      if pairing.isCancelled { return .cancelled }
      prompt.close()
      let alert = makeHueAlert()
      alert.messageText = "Couldn’t connect to Hue Bridge"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "Refresh")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Enter IP Address…")
      switch alert.runModal() {
      case .alertFirstButtonReturn: return .refresh
      case .alertThirdButtonReturn: return .switchMode
      default: return .cancelled
      }
    }
  }

  private static func connectManually() async throws -> ConnectionResult {
    let alert = makeHueAlert()
    alert.messageText = "Connect Bridge"
    alert.informativeText = "Enter your Philips Hue bridge details and application key."
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")

    let addressField = NSTextField(string: "")
    let idField = NSTextField(string: "")
    let pathField = NSTextField(string: "")
    let keyField = NSSecureTextField(string: "")
    let fields: [(String, NSTextField)] = [
      ("Bridge address", addressField), ("Bridge ID", idField),
      ("Hue root CA PEM path (optional)", pathField), ("Application key", keyField),
    ]
    let form = NSStackView()
    form.orientation = .vertical
    form.alignment = .leading
    for (title, field) in fields {
      let label = NSTextField(labelWithString: title)
      field.setAccessibilityLabel(title)
      form.addArrangedSubview(label)
      form.addArrangedSubview(field)
      field.widthAnchor.constraint(equalToConstant: 320).isActive = true
    }
    let link = NSButton(
      title: "Connect automatically", target: NSApp, action: NSSelectorFromString("stopModal")
    )
    link.isBordered = false
    link.contentTintColor = .linkColor
    form.addArrangedSubview(link)
    form.setFrameSize(form.fittingSize)
    alert.accessoryView = form
    alert.layout()
    alert.window.initialFirstResponder = addressField
    NSApp.activate()
    let response = alert.runModal()
    alert.window.orderOut(nil)
    if response == .stop { return .switchMode }
    guard response == .alertFirstButtonReturn else { return .cancelled }

    let name = try await HueConnections.add(
      address: addressField.stringValue, id: idField.stringValue,
      key: keyField.stringValue, path: pathField.stringValue
    )
    return .connected(name)
  }

  private static func showConnectionConfirmation(for name: String) {
    let alert = makeHueAlert()
    alert.messageText = "Successfully connected to Hue bridge “\(name)”"
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}

@MainActor
private final class HuePairingPrompt: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  private let alert = makeHueAlert()
  private let accessory = NSView()
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "Looking for Hue bridges…")
  private lazy var primary = alert.addButton(withTitle: "Continue")
  private lazy var manualButton = NSButton(
    title: "Enter IP Address…", target: self, action: #selector(manualPressed)
  )
  private var bridges: [DiscoveredHueBridge] = []
  private var names: [Int: String] = [:]
  private var selection: CheckedContinuation<(DiscoveredHueBridge, String)?, Never>?
  private var retry: CheckedContinuation<Bool, Never>?
  private(set) var manual = false
  private(set) var refreshRequested = false
  var cancelPairing: (() -> Void)?

  func show() {
    alert.messageText = "Add Hue Bridge"
    primary.target = self
    primary.action = #selector(connectPressed)
    primary.isEnabled = false
    let cancel = alert.addButton(withTitle: "Cancel")
    cancel.target = self
    cancel.action = #selector(cancelPressed)
    cancel.keyEquivalent = "\u{1b}"
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .lineBorder
    scroll.documentView = table
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bridge"))
    column.width = 405
    table.addTableColumn(column)
    table.headerView = nil
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.style = .plain
    table.usesAlternatingRowBackgroundColors = true
    table.setAccessibilityLabel("Discovered Hue bridges")
    table.dataSource = self
    table.delegate = self

    let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
    refresh.bezelStyle = .rounded
    manualButton.isBordered = false
    manualButton.contentTintColor = .linkColor
    let controls = NSStackView(views: [manualButton, NSView(), refresh])
    let content = NSStackView(views: [message, scroll, controls])
    content.orientation = .vertical
    content.alignment = .leading
    NSLayoutConstraint.activate([
      message.widthAnchor.constraint(equalToConstant: 420),
      scroll.widthAnchor.constraint(equalTo: message.widthAnchor),
      scroll.heightAnchor.constraint(equalToConstant: 124),
      controls.widthAnchor.constraint(equalTo: message.widthAnchor),
    ])
    accessory.setFrameSize(content.fittingSize)
    replaceAccessoryContent(with: content)
    alert.accessoryView = accessory
    alert.layout()
    NSApp.activate()
    alert.window.makeKeyAndOrderFront(nil)
  }

  func choose(from bridges: [DiscoveredHueBridge]) async -> (DiscoveredHueBridge, String)? {
    self.bridges = bridges
    table.reloadData()
    message.stringValue = bridges.isEmpty
      ? "No new Hue bridges found. Check that this Mac and the bridge are on the same network."
      : "Select a Hue bridge to connect."
    if bridges.isEmpty {
      primary.title = manualButton.title
      primary.action = #selector(manualPressed)
      primary.isEnabled = true
      manualButton.isHidden = true
      if let content = accessory.subviews.first {
        accessory.setFrameSize(content.fittingSize)
      }
      alert.layout()
    }
    let lookup = Task {
      await withTaskGroup(of: (Int, String).self) { group in
        for (index, bridge) in bridges.enumerated() {
          group.addTask { (index, await bridge.displayName()) }
        }
        for await (index, name) in group {
          if Task.isCancelled { break }
          names[index] = name
          table.reloadData(
            forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0)
          )
        }
      }
    }
    defer { lookup.cancel() }
    return await withCheckedContinuation { continuation in
      selection = continuation
      if bridges.count == 1 {
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      }
    }
  }

  func showPairing(for name: String) {
    alert.messageText = "Press the link button"
    let width: CGFloat = 320
    let illustration = NSHostingView(rootView: HueLinkButtonIllustration())
    let instruction = NSTextField(
      wrappingLabelWithString: "Press the physical link button on “\(name)”."
    )
    instruction.alignment = .center
    instruction.preferredMaxLayoutWidth = width
    status.alignment = .center
    status.preferredMaxLayoutWidth = width
    status.textColor = .secondaryLabelColor
    let content = NSStackView(views: [illustration, instruction, status])
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 10
    content.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
    NSLayoutConstraint.activate([
      illustration.widthAnchor.constraint(equalToConstant: width),
      illustration.heightAnchor.constraint(equalToConstant: 104),
      instruction.widthAnchor.constraint(equalTo: illustration.widthAnchor),
      status.widthAnchor.constraint(equalTo: illustration.widthAnchor),
    ])
    showWaiting()
    accessory.setFrameSize(content.fittingSize)
    replaceAccessoryContent(with: content)
    alert.layout()
  }

  private func replaceAccessoryContent(with content: NSView) {
    // Keep the same accessory attached to the visible alert while changing steps.
    accessory.subviews.forEach { $0.removeFromSuperview() }
    content.translatesAutoresizingMaskIntoConstraints = false
    accessory.addSubview(content)
    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
      content.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
    ])
  }

  private func showWaiting() {
    primary.isHidden = true
    primary.isEnabled = false
    status.stringValue = "Waiting for button press…"
  }

  func showVerification() {
    status.stringValue = "Verifying the bridge connection…"
  }

  func waitForRetry() async -> Bool {
    guard !Task.isCancelled else { return false }
    status.stringValue = HueError.pairingTimedOut.localizedDescription
    primary.title = "Try Again"
    primary.action = #selector(retryPressed)
    primary.isHidden = false
    primary.isEnabled = true
    alert.layout()
    return await withCheckedContinuation { retry = $0 }
  }

  @objc private func retryPressed() {
    guard let retry else { return }
    self.retry = nil
    showWaiting()
    alert.layout()
    retry.resume(returning: true)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { bridges.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let bridge = bridges[row]
    let label = NSTextField(labelWithString: "\(name(for: row)) · \(bridge.internalipaddress)")
    label.lineBreakMode = .byTruncatingMiddle
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard selection != nil else { return }
    primary.isEnabled = bridges.indices.contains(table.selectedRow)
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    selection != nil
  }

  func close() {
    alert.window.orderOut(nil)
  }

  @objc private func cancelPressed() {
    close()
    cancelPairing?()
    selection?.resume(returning: nil)
    selection = nil
    retry?.resume(returning: false)
    retry = nil
  }

  @objc private func connectPressed() {
    let row = table.selectedRow
    guard let selection, bridges.indices.contains(row) else { return }
    self.selection = nil
    primary.isEnabled = false
    selection.resume(returning: (bridges[row], name(for: row)))
  }

  private func name(for row: Int) -> String {
    names[row] ?? "Hue Bridge \(bridges[row].id.uppercased())"
  }

  @objc private func manualPressed() {
    manual = true
    cancelPressed()
  }

  @objc private func refreshPressed() {
    refreshRequested = true
    cancelPressed()
  }
}

private struct HueLinkButtonIllustration: View {
  @Environment(\.colorScheme) private var colorScheme

  private var dark: Bool { colorScheme == .dark }
  private let buttonOutline = Color(red: 0.25, green: 0.43, blue: 0.48)

  var body: some View {
    ZStack {
      HueAmbientWash()
      RoundedRectangle(cornerRadius: 19)
        .fill(.linearGradient(colors: [.white, Color(white: 0.87)], startPoint: .top, endPoint: .bottom))
        .strokeBorder(Color(white: 0.75))
        .frame(width: 68, height: 66)
        .shadow(color: .black.opacity(0.20), radius: 4, y: 3)
        .overlay {
          Circle()
            .strokeBorder(buttonOutline)
            .frame(width: 33, height: 33)
            .background {
              Circle()
                .strokeBorder(buttonOutline)
                .frame(width: 39, height: 39)
            }
        }
        .overlay(alignment: .top) {
          HStack(spacing: 5) {
            ForEach(0..<3) { _ in
              Circle().fill(buttonOutline).frame(width: 3, height: 3)
            }
          }
          .padding(.top, 8)
        }
        .overlay(alignment: .leading) {
          HStack(spacing: 0) {
            Rectangle().frame(width: 25, height: 1)
            Text("Link button")
              .font(.caption.bold())
              .padding(.horizontal, 5)
              .padding(.vertical, 3)
              .background(dark ? Color(white: 0.15) : .white, in: .rect(cornerRadius: 4))
          }
          .foregroundStyle(
            dark ? Color(red: 0.70, green: 0.96, blue: 0.92) : Color(red: 0.10, green: 0.34, blue: 0.39)
          )
          .fixedSize()
          .offset(x: 50)
        }
    }
    .clipShape(.rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct HueAmbientWash: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var settled = false

  var body: some View {
    let dark = colorScheme == .dark
    let drift: CGFloat = settled || reduceMotion ? 1 : 0

    Color(white: dark ? 0.16 : 0.94)
      .overlay {
        ZStack {
          glow(.orange, opacity: dark ? 0.32 : 0.40)
            .offset(x: -105 + 16 * drift, y: -30 + 6 * drift)
          glow(.mint, opacity: dark ? 0.30 : 0.42)
            .offset(x: 113 - 14 * drift, y: -22 + 4 * drift)
          glow(.blue, opacity: dark ? 0.33 : 0.31)
            .offset(x: 4 + 13 * drift, y: 64 - 7 * drift)
        }
      }
    .animation(reduceMotion ? nil : .easeInOut(duration: 5), value: drift)
    .id(reduceMotion)
    .onAppear { settled = true }
  }

  private func glow(_ tint: Color, opacity: Double) -> some View {
    Circle()
      .fill(.radialGradient(
        colors: [tint.opacity(opacity), tint.opacity(0)],
        center: .center,
        startRadius: 12,
        endRadius: 111
      ))
      .frame(width: 222, height: 222)
  }
}

@MainActor
private final class HueAlert: NSAlert {
  override func layout() {
    super.layout()
    // AppKit chooses the alert layout. Move only the view displaying our icon.
    guard let content = window.contentView,
          let iconView = content.subviews.compactMap({ $0 as? NSImageView })
            .first(where: { $0.image === icon }) else { return }
    iconView.frame.origin.x = content.bounds.midX - iconView.frame.width / 2
  }

  override func runModal() -> NSApplication.ModalResponse {
    layout()
    return super.runModal()
  }
}

@MainActor
func makeHueAlert() -> NSAlert {
  let alert = HueAlert()
  guard let logo = Bundle(for: HueExtension.self).image(forResource: "HueAlertIcon") else {
    return alert
  }
  alert.icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
    logo.draw(in: rect.insetBy(dx: 9, dy: 9), from: .zero, operation: .sourceOver, fraction: 1)
    return true
  }
  return alert
}
