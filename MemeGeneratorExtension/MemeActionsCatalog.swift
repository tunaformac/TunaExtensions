import AppKit
import Foundation
import TunaKit

public final class MemeActionsCatalog: ActionCatalog {
  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  private static func makeActions() -> [CatalogAction] {
    [makeMemeAction(), favoriteAction(true), favoriteAction(false), copyImageAction(), copyURLAction()]
  }

  // MARK: Make Meme

  private static func makeMemeAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: "make-meme", title: "Make Meme", executionPolicy: .keepVisible
    ) { subject, target in
      guard let item = subject as? MemeTemplateItem else {
        return .failure("Select a meme template")
      }
      let text = target?.textInputValue() ?? ""
      return await MemeMaker.make(template: item.template, text: text)
    }
    action.systemSymbolName = "face.smiling"
    // Optional: Enter runs right away with the template's example text; typed text overrides it.
    action.targetRequirement = .optional
    action.supportedSubjectTypes = [.memeTemplate]
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = { $0 is MemeTemplateItem }
    action.targetPredicate = { target in
      guard let text = target?.textInputValue() else { return false }
      return MemeText.hasText(text)
    }
    action.targetTextSeedProvider = { subject in
      (subject as? MemeTemplateItem)?.template.textSeed
    }
    return action
  }

  // MARK: Favorites

  private static func favoriteAction(_ favorite: Bool) -> CatalogAction {
    let action = PredicateAwareAction(
      id: favorite ? "add-favorite" : "remove-favorite",
      title: favorite ? "Add to Favorites" : "Remove from Favorites",
      headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? MemeTemplateItem else {
        return .failure("Select a meme template")
      }
      MemeFavorites.live.set(item.template, favorite: favorite)
      NotificationCenter.default.post(name: .memeTemplatesDidChange, object: nil)
      return .success
    }
    action.systemSymbolName = favorite ? "star" : "star.slash"
    action.supportedSubjectTypes = [.memeTemplate]
    action.subjectPredicate = { subject in
      guard let item = subject as? MemeTemplateItem else { return false }
      return item.isFavorite != favorite
    }
    return action
  }

  // MARK: Copy

  private static func copyImageAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: "copy-image", title: "Copy Image", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? MemeImageItem else { return .failure("Select a meme") }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      let copied = pasteboard.setData(
        item.meme.imageData, forType: MemeImageItem.pasteboardType(for: item.meme))
      return copied ? .success : .failure("Failed to copy the meme")
    }
    action.systemSymbolName = "doc.on.doc"
    action.supportedSubjectTypes = [.memeImage]
    action.subjectPredicate = { $0 is MemeImageItem }
    return action
  }

  private static func copyURLAction() -> CatalogAction {
    let action = PredicateAwareAction(
      id: "copy-url", title: "Copy URL", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? MemeImageItem else { return .failure("Select a meme") }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      return pasteboard.setString(item.meme.remoteURL.absoluteString, forType: .string)
        ? .success
        : .failure("Failed to copy the meme URL")
    }
    action.systemSymbolName = "link"
    action.supportedSubjectTypes = [.memeImage]
    action.subjectPredicate = { $0 is MemeImageItem }
    return action
  }
}

enum MemeMaker {
  static func make(
    template: MemeTemplate,
    text: String,
    client: MemeAPIClient = .live,
    credentials: ImgflipCredentials? = MemeSettings.imgflipCredentials,
    directory: URL = MemeFileStore.directory
  ) async -> ActionResult {
    let lines = MemeText.resolvedLines(from: text, template: template)
    do {
      // Templates without example text (all of Imgflip's) would otherwise render blank boxes.
      guard MemeText.hasText(lines.joined()) else { throw MemeError.emptyText }
      let meme = try await client.generate(
        template: template, lines: lines, imgflipCredentials: credentials)
      let fileURL = try MemeFileStore.write(meme, in: directory)
      return .subjects([MemeImageItem(meme: meme, fileURL: fileURL)])
    } catch {
      AppLog.warning(.actions, "Meme Generator failed: \(error.localizedDescription)")
      return .failure(error.localizedDescription)
    }
  }
}
