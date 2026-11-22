import AppKit
import Foundation
import TunaKit

/// The "Run Speed Test" command.
public final class SpeedtestCatalog: Catalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var objects: [CatalogItem] = [Self.runCommand()]

  public required init(definition: CatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  public func scan() async {
    reportScanFinished()
  }

  static func runCommand() -> CatalogItem {
    CommandItem(
      id: "speedtest.run",
      title: "Run Speed Test",
      symbol: "speedometer",
      detail: "Measure download, upload, and responsiveness with networkQuality",
      tintColor: .systemTeal,
      headlessEligibility: .guaranteed,
      executionPolicy: .dismiss
    ) {
      .background(SpeedtestRunner.task())
    }
  }
}

enum SpeedtestRunner {
  static func task() -> CommandBackgroundTask {
    CommandBackgroundTask(title: "Testing Internet Speed") {
      await CommandBackgroundTask.appendLog("Measuring download, upload, and responsiveness…")
      do {
        let result = try await NetworkQuality.run()
        await CommandBackgroundTask.appendLog(result.summary)
        return .success(results: SpeedtestResultItem.items(for: result), standardOutput: result.summary)
      } catch {
        AppLog.warning(.actions, "Speed test failed: \(error.localizedDescription)")
        return .failure(message: error.localizedDescription)
      }
    }
  }
}

final class SpeedtestResultItem: CatalogEntity, TextValueProviding, CopyRepresentationProviding,
  @unchecked Sendable
{
  enum Kind: String, CaseIterable {
    case summary, download, upload, responsiveness, idleLatency
  }

  let kind: Kind
  let result: NetworkQualityResult
  let valueText: String
  private let detailText: String?

  init(kind: Kind, result: NetworkQualityResult, title: String, valueText: String, detail: String?) {
    self.kind = kind
    self.result = result
    self.valueText = valueText
    self.detailText = detail
    super.init(id: "speedtest.result.\(kind.rawValue)", title: title, path: nil)
    typeID = .speedtestResult
  }

  override var detail: String? { detailText }
  var textValue: String { valueText }
  var copyRepresentation: String? { valueText }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    let symbol =
      switch kind {
      case .summary: "speedometer"
      case .download: "arrow.down.circle"
      case .upload: "arrow.up.circle"
      case .responsiveness: "bolt.horizontal.circle"
      case .idleLatency: "timer"
      }
    return .systemSymbol(symbol, tintColor: .systemTeal)
  }

  static func items(for result: NetworkQualityResult) -> [SpeedtestResultItem] {
    let context = [result.interfaceName, result.testEndpoint].compactMap { $0 }
      .joined(separator: " · ")
    var items = [
      SpeedtestResultItem(
        kind: .summary, result: result, title: result.summary, valueText: result.summary,
        detail: context.isEmpty ? "Speed test" : "Speed test · \(context)")
    ]
    if let value = result.downloadBitsPerSecond {
      let text = SpeedFormat.bandwidth(value)
      items.append(
        .init(kind: .download, result: result, title: "Download \(text)",
              valueText: "Download: \(text)", detail: "Download capacity"))
    }
    if let value = result.uploadBitsPerSecond {
      let text = SpeedFormat.bandwidth(value)
      items.append(
        .init(kind: .upload, result: result, title: "Upload \(text)",
              valueText: "Upload: \(text)", detail: "Upload capacity"))
    }
    if let value = result.responsivenessRPM {
      let text = SpeedFormat.rpm(value)
      let latency = SpeedFormat.loadedLatency(rpm: value)
      items.append(
        .init(kind: .responsiveness, result: result, title: "Responsiveness \(text)",
              valueText: "Responsiveness: \(text)",
              detail: latency.map { "About \($0) round trips while the connection is busy" }))
    }
    if let value = result.idleLatencyMilliseconds {
      let text = SpeedFormat.milliseconds(value)
      items.append(
        .init(kind: .idleLatency, result: result, title: "Idle Latency \(text)",
              valueText: "Idle latency: \(text)", detail: "Round trip on an idle connection"))
    }
    return items
  }
}

public final class SpeedtestActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = [Self.copySummaryAction()]

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func copySummaryAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: "copy-summary", title: "Copy Summary", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? SpeedtestResultItem else {
        return .failure("Select a speed test result")
      }
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(item.result.summary, forType: .string)
        ? .success
        : .failure("Failed to copy the summary")
    }
    action.systemSymbolName = "doc.on.doc"
    action.supportedSubjectTypes = [.speedtestResult]
    action.subjectPredicate = { $0 is SpeedtestResultItem }
    return action
  }
}
