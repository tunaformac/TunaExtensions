import AppKit
import Foundation
import TunaKit

public final class SafariActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
  }


  private static func makeActions() -> [CatalogAction] {
    var items: [CatalogAction] = []

    let openInSafari = PredicateAwareAction(
      id: "open-in-safari", title: "Open in Safari", type: .action
    ) { subject, _ in
      if SafariDynamicURLResolver.isCurrentPage(subject: subject) {
        return SafariDynamicURLResolver.openCurrentPageInSafari()
      }
      guard let url = SafariURLActions.url(from: subject) else {
        return .failure("No URL to open")
      }
      guard let safariURL = SafariURLActions.safariApplicationURL() else {
        return .failure("Safari not available")
      }
      SafariURLActions.open([url], with: safariURL)
      return .success
    }
    openInSafari.systemSymbolName = "safari"
    openInSafari.supportedSubjectTypes = [.url, .textSnippet]
    openInSafari.subjectPredicate = {
      SafariDynamicURLResolver.isCurrentPage(subject: $0) || SafariURLActions.url(from: $0) != nil
    }
    items.append(openInSafari)

    let openURL = PredicateAwareAction(id: "open-url", title: "Open URL", type: .action) {
      _, target in
      guard let url = SafariURLActions.url(from: target) else {
        return .failure("No URL to open")
      }
      guard let safariURL = SafariURLActions.safariApplicationURL() else {
        return .failure("Safari not available")
      }
      SafariURLActions.open([url], with: safariURL)
      return .success
    }
    openURL.targetRequirement = .required
    openURL.systemSymbolName = "safari"
    openURL.supportedSubjectTypes = [.application]
    openURL.allowedTargetTypes = [.textSnippet, .url]
    openURL.subjectPredicate = SafariURLActions.isSafariApplication
    openURL.targetPredicate = { SafariURLActions.url(from: $0) != nil }
    items.append(openURL)

    let copyURL = PredicateAwareAction(id: "copy-url", title: "Copy URL", type: .action) {
      subject, _ in
      if SafariDynamicURLResolver.isCurrentPage(subject: subject) {
        return SafariDynamicURLResolver.copyCurrentPageURLToClipboard()
      }
      guard let url = SafariURLActions.url(from: subject) else {
        return .failure("No URL to copy")
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      if pasteboard.setString(url.absoluteString, forType: .string) {
        return .success
      }
      return .failure("Failed to copy URL")
    }
    copyURL.systemSymbolName = "link"
    copyURL.supportedSubjectTypes = [.url, .textSnippet]
    copyURL.subjectPredicate = {
      SafariDynamicURLResolver.isCurrentPage(subject: $0) || SafariURLActions.url(from: $0) != nil
    }
    items.append(copyURL)

    let copyTargetURL = PredicateAwareAction(
      id: "copy-url.target", title: "Copy URL", type: .action
    ) { _, target in
      guard let url = SafariURLActions.url(from: target) else {
        return .failure("No URL to copy")
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      if pasteboard.setString(url.absoluteString, forType: .string) {
        return .success
      }
      return .failure("Failed to copy URL")
    }
    copyTargetURL.targetRequirement = .required
    copyTargetURL.systemSymbolName = "link"
    copyTargetURL.supportedSubjectTypes = [.application]
    copyTargetURL.allowedTargetTypes = [.textSnippet, .url]
    copyTargetURL.subjectPredicate = SafariURLActions.isSafariApplication
    copyTargetURL.targetPredicate = { SafariURLActions.url(from: $0) != nil }
    items.append(copyTargetURL)

    return items
  }
}

private enum SafariDynamicURLResolver {
  static func isCurrentPage(subject: CatalogItem?) -> Bool {
    guard let subject else { return false }
    guard let entity = subject as? CatalogEntity else { return false }
    return entity.path == SafariAppleScript.currentPageToken
  }

  static func openCurrentPageInSafari() -> ActionResult {
    ActionResult.background(
      CommandBackgroundTask(title: "Resolving Safari Current Page") {
        guard let page = SafariAppleScript.currentPageInfo() else {
          return .failure(message: "No Safari page available")
        }

        guard let safariURL = SafariURLActions.safariApplicationURL() else {
          return .failure(message: "Safari not available")
        }

        await MainActor.run {
          SafariURLActions.open([page.url], with: safariURL)
        }

        return .successWithoutResult()
      })
  }

  static func copyCurrentPageURLToClipboard() -> ActionResult {
    ActionResult.background(
      CommandBackgroundTask(title: "Resolving Safari Current Page") {
        guard let page = SafariAppleScript.currentPageInfo() else {
          return .failure(message: "No Safari page available")
        }

        let urlString = page.url.absoluteString
        let success = await MainActor.run {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          return pasteboard.setString(urlString, forType: .string)
        }

        if success {
          return .successWithoutResult()
        }

        return .failure(message: "Failed to copy URL")
      })
  }
}

private enum SafariURLActions {
  static func isSafariApplication(_ subject: CatalogItem?) -> Bool {
    guard let entity = subject as? CatalogEntity,
      let path = entity.path,
      TypeRegistry.shared.inherits(entity.typeID, from: .application)
    else { return false }
    return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.apple.Safari"
  }

  static func url(from item: CatalogItem?) -> URL? {
    guard let item else { return nil }

    if let text = item.textValueFallback(), let url = url(fromString: text) {
      return url
    }

    if let entity = item as? CatalogEntity {
      if let path = entity.path, let url = url(fromString: path) {
        return url
      }
      if let extended = entity.extended, let url = url(fromString: extended) {
        return url
      }
      if let detail = entity.detail, let url = url(fromString: detail) {
        return url
      }
      return url(fromString: entity.title)
    }

    if let extended = item.extended, let url = url(fromString: extended) {
      return url
    }
    if let detail = item.detail, let url = url(fromString: detail) {
      return url
    }
    return url(fromString: item.title)
  }

  static func safariApplicationURL() -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
  }

  static func open(_ urls: [URL], with safariURL: URL) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open(
      urls,
      withApplicationAt: safariURL,
      configuration: configuration,
      completionHandler: { _, error in
        if let error {
          AppLog.error(.actions, "Open in Safari failed: \(error.localizedDescription)")
        }
      })
  }

  private static func url(fromString string: String?) -> URL? {
    guard let string else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
      return nil
    }
    return url
  }
}
