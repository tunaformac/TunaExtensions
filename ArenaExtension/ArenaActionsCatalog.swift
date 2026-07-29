import AppKit
import Foundation
import TunaKit

public final class ArenaActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeActions() -> [CatalogAction] {
    let capture = PredicateAwareAction(
      id: "capture", title: "Save to Are.na", type: .action
    ) { subject, target in
      guard let value = captureValue(from: subject) else {
        return .failure("Select a URL or text to save")
      }
      guard let channel = target as? ArenaChannelItem else {
        return .failure("Choose an Are.na channel")
      }
      guard channel.connection.canWrite else {
        return .failure("Reconnect Are.na in extension settings to grant write access")
      }

      let connection = channel.connection
      let channelID = channel.channel.id
      return .background(
        CommandBackgroundTask(title: "Saving to Are.na") {
          do {
            let block = try await ArenaAPIClient(connection: connection).createBlock(
              value: value, channelID: channelID)
            return .success(
              results: [ArenaBlockItem(block: block, connectionID: connection.record.id)])
          } catch {
            return .failure(message: error.localizedDescription)
          }
        })
    }
    capture.targetRequirement = .required
    capture.systemSymbolName = "square.and.arrow.down"
    capture.supportedSubjectTypes = [.url, .textSnippet]
    capture.allowedTargetTypes = [.arenaChannel]
    capture.subjectPredicate = { captureValue(from: $0) != nil }
    capture.targetPredicate = { $0 is ArenaChannelItem }

    let openChannel = PredicateAwareAction(
      id: "open-channel", title: "Open on Are.na", type: .action
    ) { subject, _ in
      guard let channel = subject as? ArenaChannelItem else {
        return .failure("No Are.na channel selected")
      }
      NSWorkspace.shared.open(channel.channel.url)
      return .success
    }
    openChannel.systemSymbolName = "arrow.up.right.square"
    openChannel.supportedSubjectTypes = [.arenaChannel]
    openChannel.subjectPredicate = { $0 is ArenaChannelItem }

    let openBlock = PredicateAwareAction(
      id: "open-block", title: "Open on Are.na", type: .action
    ) { subject, _ in
      guard let block = subject as? ArenaBlockItem else {
        return .failure("No Are.na block selected")
      }
      NSWorkspace.shared.open(block.block.arenaURL)
      return .success
    }
    openBlock.systemSymbolName = "arrow.up.right.square"
    openBlock.supportedSubjectTypes = [.arenaBlock]
    openBlock.subjectPredicate = { $0 is ArenaBlockItem }

    return [capture, openChannel, openBlock, ArenaResolveAction()]
  }

  private static func captureValue(from item: CatalogItem?) -> String? {
    guard let item else { return nil }

    if TypeRegistry.shared.inherits(item.typeID, from: .url),
      let entity = item as? CatalogEntity,
      let path = entity.path,
      let url = URL(string: path),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      return url.absoluteString
    }

    guard TypeRegistry.shared.inherits(item.typeID, from: .textSnippet) else { return nil }
    let value = item.textValueFallback()?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}

private final class ArenaResolveAction: CatalogAction, AsyncActionProviding,
  ActionPredicateProviding, @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate? = {
    $0 is ArenaBlockItem || $0 is ArenaChannelItem
  }
  var targetPredicate: CatalogActionTargetPredicate?

  init() {
    super.init(id: "resolve", title: "Resolve", type: .action) { _, _ in
      .failure("Nothing to resolve")
    }
    systemSymbolName = "arrow.down.circle"
    supportedSubjectTypes = [.arenaBlock, .arenaChannel]
    producesInlineResult = true
  }

  func performAsync(subjects: [CatalogItem], target: CatalogItem?) async -> ActionResult {
    do {
      var resolved: [CatalogItem] = []
      resolved.reserveCapacity(subjects.count)
      for subject in subjects {
        if let channel = subject as? ArenaChannelItem {
          resolved.append(URLItem(urlString: channel.channel.url.absoluteString))
        } else if let block = subject as? ArenaBlockItem {
          resolved.append(try await ArenaBlockResolver.shared.resolve(block.block))
        } else {
          throw ArenaResolutionError.unsupportedItem
        }
      }
      return resolved.isEmpty ? .failure("Nothing to resolve") : .subjects(resolved)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}
