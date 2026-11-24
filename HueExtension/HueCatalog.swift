import AppKit
import OSLog
import TunaKit

@MainActor
public final class HueCatalog: Catalog, CatalogDiagnosticsReporting {
  public let identifier: String
  public let name: String
  public private(set) var objects: [CatalogItem] = []

  private let logger = Logger(subsystem: "de.bjesuiter.tuna.hue", category: "catalog")
  private var scanID = UUID()
  private var status = "Waiting for first scan"
  private var connecting = false

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async {
    let currentScan = UUID()
    scanID = currentScan
    var items: [CatalogItem] = []
    do {
      let records = try HueConnections.records()
      let groupsByBridge = await withTaskGroup(
        of: (String, Result<[HueGroup], Error>).self
      ) { tasks in
        for id in records.keys {
          tasks.addTask {
            do {
              let groups = try await HueConnections.use(id) { bridge in
                async let name = try? bridge.name()
                let groups = try await bridge.groups()
                return (groups, await name)
              }
              if let name = groups.1, let generation = records[id]?.generation {
                try? await HueConnections.updateName(name, for: id, generation: generation)
              }
              return (id, .success(groups.0))
            } catch {
              return (id, .failure(error))
            }
          }
        }
        var results: [String: Result<[HueGroup], Error>] = [:]
        for await (id, result) in tasks { results[id] = result }
        return results
      }
      guard scanID == currentScan, !Task.isCancelled else { return }
      let current = try HueConnections.records()
      if !current.isEmpty {
        items.append(bridgeCommand(manage: true))
      }
      var groupCount = 0
      var failed = 0
      for id in current.keys.sorted() {
        guard let record = current[id], records[id]?.generation == record.generation,
              let result = groupsByBridge[id] else { continue }
        switch result {
        case .success(let groups):
          groupCount += groups.count
          let bridgeLabel = Self.label(for: record, among: current)
          items += groups.map { group in
            HueGroupItem(group: group, bridge: record, bridgeLabel: bridgeLabel) { [weak self] group in
              guard let self else { return }
              let current = objects.compactMap { $0 as? HueGroupItem }.first {
                $0.bridgeID == record.id && $0.group.id == group.id && $0.group.kind == group.kind
              }
              current?.updateGroup(group)
              reportScanFinished()
            }
          }
        case .failure(let error):
          failed += 1
          logger.error("Hue scan for \(record.name, privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
        }
      }
      items.append(bridgeCommand(manage: false, first: current.isEmpty))
      status = current.isEmpty ? "No Hue bridges connected"
        : "Loaded \(groupCount) Hue groups from \(current.count - failed) of \(current.count) bridges"
    } catch {
      guard scanID == currentScan, !Task.isCancelled else { return }
      status = error.localizedDescription
      logger.error("Hue catalog scan failed: \(self.status, privacy: .private)")
    }
    objects = items
    reportScanFinished()
  }

  public func diagnosticsSnapshot() -> CatalogDiagnosticsSnapshot {
    CatalogDiagnosticsSnapshot(metrics: ["Hue": .text(status)])
  }

  private static func label(for record: HueConnection, among records: [String: HueConnection]) -> String {
    let duplicate = records.values.contains {
      $0.id != record.id && $0.name.localizedCaseInsensitiveCompare(record.name) == .orderedSame
    }
    return duplicate ? "\(record.name) (\(record.id.uppercased()))" : record.name
  }

  private func bridgeCommand(manage: Bool, first: Bool = false) -> CatalogItem {
    let title = manage ? "Manage Hue Bridges" : (first ? "Connect First Hue Bridge" : "Add Hue Bridge")
    let command = CommandItem(
      id: manage ? "manage-bridges" : "connect-bridge",
      title: title,
      symbol: manage ? "gearshape" : "link",
      detail: "Philips Hue", tintColor: .systemOrange,
      headlessEligibility: .requiresInterface, executionPolicy: .dismiss
    ) { [weak self] in
      guard let self, !connecting else { return .success }
      connecting = true
      defer { connecting = false }
      do {
        let changed = try await (manage ? Self.manageBridges() : HuePairing.connect())
        if changed { await scan() }
        return .success
      } catch {
        return .failure(error.localizedDescription)
      }
    }
    return manage ? command : ConnectHueBridgeItem(command: command, first: first)
  }

  private static func manageBridges() throws -> Bool {
    let records = try HueConnections.records()
    let sorted = records.values.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    NSApp.activate()
    let alert = makeHueAlert()
    alert.messageText = "Manage Hue Bridges"
    guard !sorted.isEmpty else {
      alert.informativeText = "No Hue bridges are connected. Use Connect First Hue Bridge to connect one."
      alert.addButton(withTitle: "Done")
      alert.runModal()
      return false
    }

    alert.informativeText = "Choose a connected bridge to disconnect."
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Disconnect…")
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    picker.setAccessibilityLabel("Connected Hue bridges")
    picker.addItems(withTitles: sorted.map {
      "\(label(for: $0, among: records)) · \($0.address)"
    })
    alert.accessoryView = picker
    guard alert.runModal() == .alertSecondButtonReturn,
          sorted.indices.contains(picker.indexOfSelectedItem) else { return false }
    alert.window.orderOut(nil)

    let record = sorted[picker.indexOfSelectedItem]
    let confirm = makeHueAlert()
    confirm.alertStyle = .warning
    confirm.messageText = "Disconnect “\(label(for: record, among: records))”?"
    confirm.informativeText = "Tuna will remove this bridge and its saved application key from this Mac."
    let cancel = confirm.addButton(withTitle: "Cancel")
    confirm.addButton(withTitle: "Disconnect")
    confirm.layout()
    let window = confirm.window
    window.defaultButtonCell = cancel.cell as? NSButtonCell
    // Setting a default button replaces Cancel's Escape shortcut with Return.
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.window === window, event.charactersIgnoringModifiers == "\u{1b}" else { return event }
      cancel.performClick(nil)
      return nil
    }
    defer { if let escape { NSEvent.removeMonitor(escape) } }
    guard confirm.runModal() == .alertSecondButtonReturn else { return false }
    try HueConnections.disconnect(record.id)
    return true
  }
}
