import AppKit
import Foundation
import TunaKit

private final class SubjectTextSearchAction: CatalogAction, ActionPredicateProviding,
  SubjectScopedSearchActionProviding, @unchecked Sendable
{
  var subjectPredicate: CatalogActionSubjectPredicate?
  var targetPredicate: CatalogActionTargetPredicate?
  var subjectScopedSearchRootCatalogIdentifier: String? { "brew.search" }

  init(id: String, title: String) {
    super.init(id: id, title: title) { _, _ in .success }
  }

  func subjectScopedSearchQuery(from subject: CatalogItem) -> String? {
    subject.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func subjectScopedSearchRoot(for _: CatalogItem) -> CatalogItem? {
    BrewMetaItem(title: "Homebrew", detail: "Search Homebrew packages and casks")
  }
}

enum BrewSettings {
  static let customBrewPathKey = "CustomBrewPath"
  static let customBrewPathDefault = ""

  static var customBrewPath: String? {
    let store = CatalogSettingStore(catalogIdentifier: extensionIdentifier)
    let value = store.stringValue(for: customBrewPathKey, defaultValue: customBrewPathDefault)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    return value
  }

  private static let extensionIdentifier: String = {
    let bundle = Bundle(for: BrewExtension.self)
    return bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaBrew")
  }()
}

enum BrewActionsCatalog {
  enum ID {
    static let listInstalled = "browse-installed"
    static let listOutdated = "browse-outdated"
    static let update = "update"
    static let upgradeAll = "upgrade-all"
    static let cleanup = "cleanup"
    static let install = "install-from-text"
    static let installCask = "install-cask"

    static let packageInstall = "install"
    static let packageUninstall = "uninstall"
    static let packageUpgrade = "upgrade"
    static let packageOpenPage = "open-info"
  }

  enum Key {
    static let listInstalled = "Browse Installed"
    static let listOutdated = "Browse Outdated"
    static let update = "Update"
    static let upgradeAll = "Upgrade"
    static let cleanup = "Cleanup"
    static let install = "Install ..."
    static let installCask = "Install cask ..."

    static let textSearch = "Search Homebrew packages"

    static let packageInstall = "Install"
    static let packageUninstall = "Uninstall"
    static let packageUpgrade = "Upgrade"
    static let packageOpenPage = "Open Info"
  }

  static let packageActionIDs: Set<String> = [
    ID.packageInstall, ID.packageUninstall, ID.packageUpgrade, ID.packageOpenPage,
  ]

  static let metaActionIDs: Set<String> = [
    ID.listInstalled, ID.listOutdated, ID.update, ID.upgradeAll, ID.cleanup, ID.install,
    ID.installCask,
  ]

  static func packageActions() -> [CatalogAction] {
    [
      packageInstallAction(), packageUninstallAction(), packageUpgradeAction(),
      packageOpenPageAction(),
    ]
  }

  static func actions() -> [CatalogAction] {
    [
      listInstalledAction(), listOutdatedAction(), updateAction(), upgradeAllAction(),
      cleanupAction(), installAction(), installCaskAction(), textSearchAction(),
    ] + packageActions()
  }

  private static func listInstalledAction() -> CatalogAction {
    packageListAction(
      id: ID.listInstalled,
      title: Key.listInstalled,
      symbol: "checkmark.circle",
      emptyTitle: "No Installed Packages",
      emptyMessage: "No installed Homebrew packages were found."
    ) {
      try await BrewDataStore.shared.installed(customBrewPath: BrewSettings.customBrewPath)
    }
  }

  private static func listOutdatedAction() -> CatalogAction {
    packageListAction(
      id: ID.listOutdated,
      title: Key.listOutdated,
      symbol: "arrow.triangle.2.circlepath.circle",
      emptyTitle: "All Up To Date",
      emptyMessage: "All installed Homebrew packages are up to date."
    ) {
      try await BrewDataStore.shared.outdated(customBrewPath: BrewSettings.customBrewPath)
    }
  }

  private static func installAction() -> CatalogAction {
    metaTextInstallAction(
      id: ID.install, title: Key.install, symbol: "arrow.down.circle", asCask: false)
  }

  private static func installCaskAction() -> CatalogAction {
    metaTextInstallAction(
      id: ID.installCask, title: Key.installCask, symbol: "shippingbox", asCask: true)
  }

  private static func updateAction() -> CatalogAction {
    brewMetaCommandAction(
      id: ID.update, title: Key.update, symbol: "arrow.clockwise", arguments: ["update"])
  }

  private static func upgradeAllAction() -> CatalogAction {
    brewMetaCommandAction(
      id: ID.upgradeAll,
      title: Key.upgradeAll,
      symbol: "arrow.up.circle",
      arguments: ["upgrade"]
    )
  }

  private static func cleanupAction() -> CatalogAction {
    brewMetaCommandAction(
      id: ID.cleanup, title: Key.cleanup, symbol: "sparkles", arguments: ["cleanup"])
  }

  private static func metaTextInstallAction(
    id: String,
    title: String,
    symbol: String,
    asCask: Bool
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, target in
      guard subject.typeID == TypeID.brewMeta else { return .failure("Select Homebrew first") }
      guard let input = target?.textInputValue() else { return .failure("Enter a package name") }
      let packages = packageInputTokens(from: input)
      guard !packages.isEmpty else { return .failure("Enter a package name") }

      let joined = packages.joined(separator: ", ")
      let taskTitle = asCask ? "Installing cask \(joined)" : "Installing \(joined)"
      let arguments = asCask ? (["install", "--cask"] + packages) : (["install"] + packages)
      return brewCommandTask(title: taskTitle, arguments: arguments)
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [TypeID.brewMeta]
    action.targetRequirement = .required
    action.allowedTargetTypes = [.textSnippet]
    action.subjectPredicate = { subject in subject?.typeID == TypeID.brewMeta }
    action.targetPredicate = { target in
      guard let text = target?.textInputValue() else { return false }
      return !packageInputTokens(from: text).isEmpty
    }
    return action
  }

  private static func packageListAction(
    id: String,
    title: String,
    symbol: String,
    emptyTitle: String,
    emptyMessage: String,
    load: @escaping @Sendable () async throws -> [BrewPackageRecord]
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard subject.typeID == TypeID.brewMeta else { return .failure("Select Homebrew first") }
      return .background(
        CommandBackgroundTask(title: title) {
          do {
            let items = try await load()
            if items.isEmpty {
              return .success(results: [
                CatalogMessageItem(
                  title: emptyTitle,
                  message: emptyMessage,
                  symbolName: symbol,
                  tintColor: .secondaryLabelColor
                )
              ])
            }
            return .success(results: items.map(BrewPackageItem.init))
          } catch {
            return .success(results: [homebrewUnavailableMessage(error)])
          }
        }
      )
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [TypeID.brewMeta]
    action.executionPolicy = .keepVisible
    action.subjectPredicate = { subject in subject?.typeID == TypeID.brewMeta }
    return action
  }

  private static func textSearchAction() -> CatalogAction {
    let action = SubjectTextSearchAction(id: "search-homebrew-packages", title: Key.textSearch)
    action.systemSymbolName = "magnifyingglass"
    action.supportedSubjectTypes = [.textSnippet]
    action.subjectPredicate = { subject in
      subject?.textInputValue() != nil
    }
    action.executionPolicy = .keepVisible
    return action
  }

  private static func brewMetaCommandAction(
    id: String,
    title: String,
    symbol: String,
    arguments: [String]
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard subject.typeID == TypeID.brewMeta else { return .failure("Select Homebrew first") }
      return brewCommandTask(title: title, arguments: arguments)
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [TypeID.brewMeta]
    action.subjectPredicate = { subject in subject?.typeID == TypeID.brewMeta }
    return action
  }

  private static func brewCommandTask(title: String, arguments: [String]) -> ActionResult {
    .background(
      CommandBackgroundTask(title: title) {
        do {
          let output = try await BrewDataStore.shared.runCommand(
            arguments: arguments,
            customBrewPath: BrewSettings.customBrewPath
          )
          return .successWithoutResult(standardOutput: output.combinedOutput)
        } catch {
          AppLog.error(
            .plugins, "[Brew] command failed title=\(title) error=\(error.localizedDescription)")
          return .failure(message: error.localizedDescription)
        }
      }
    )
  }

  private static func packageInputTokens(from text: String) -> [String] {
    text
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .map(String.init)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func packageInstallAction() -> CatalogAction {
    packageAction(
      id: ID.packageInstall,
      title: Key.packageInstall,
      symbol: "arrow.down.circle",
      predicate: { !$0.isInstalled },
      command: .install
    )
  }

  private static func packageUninstallAction() -> CatalogAction {
    packageAction(
      id: ID.packageUninstall,
      title: Key.packageUninstall,
      symbol: "trash",
      predicate: \.isInstalled,
      command: .uninstall
    )
  }

  private static func packageUpgradeAction() -> CatalogAction {
    packageAction(
      id: ID.packageUpgrade,
      title: Key.packageUpgrade,
      symbol: "arrow.up.circle",
      predicate: \.isOutdated,
      command: .upgrade
    )
  }

  private static func packageOpenPageAction() -> CatalogAction {
    packageAction(
      id: ID.packageOpenPage, title: Key.packageOpenPage, symbol: "safari", predicate: { _ in true }
    ) {
      package in
      guard let url = BrewPackagePageURL(package: package).url else {
        return .failure("Could not build Homebrew package URL")
      }
      NSWorkspace.shared.open(url)
      return .success
    }
  }

  private static func packageAction(
    id: String,
    title: String,
    symbol: String,
    predicate: @escaping (BrewPackageItem) -> Bool,
    perform: @escaping (BrewPackageItem) -> ActionResult
  ) -> CatalogAction {
    let action = PredicateAwareAction(id: id, title: title) { subject, _ in
      guard let package = subject as? BrewPackageItem else {
        return .failure("No Homebrew package selected")
      }
      return perform(package)
    }
    action.systemSymbolName = symbol
    action.supportedSubjectTypes = [.brewPackage]
    action.subjectPredicate = { subject in
      guard let package = subject as? BrewPackageItem else { return false }
      return predicate(package)
    }
    return action
  }

  private static func packageAction(
    id: String,
    title: String,
    symbol: String,
    predicate: @escaping (BrewPackageItem) -> Bool,
    command: BrewCommand
  ) -> CatalogAction {
    packageAction(id: id, title: title, symbol: symbol, predicate: predicate) { package in
      BrewBackgroundTask(command: command, package: package).actionResult
    }
  }
}

private func homebrewUnavailableMessage(_ error: Error) -> CatalogMessageItem {
  CatalogMessageItem(
    title: "Homebrew Unavailable",
    message: error.localizedDescription,
    symbolName: "exclamationmark.triangle",
    tintColor: .systemOrange
  )
}

private struct BrewPackagePageURL {
  let package: BrewPackageItem

  var url: URL? {
    guard
      let escapedName = package.packageName.addingPercentEncoding(
        withAllowedCharacters: Self.pathComponentAllowed)
    else {
      return nil
    }
    let kindPath = package.kind == .cask ? "cask" : "formula"
    return URL(string: "https://formulae.brew.sh/\(kindPath)/\(escapedName)")
  }

  private static let pathComponentAllowed: CharacterSet = {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return allowed
  }()
}

private struct BrewBackgroundTask {
  let command: BrewCommand
  let package: BrewPackageItem

  var actionResult: ActionResult {
    let title = title
    let arguments = arguments
    return .background(
      CommandBackgroundTask(title: title) {
        do {
          let output = try await BrewDataStore.shared.runCommand(
            arguments: arguments,
            customBrewPath: BrewSettings.customBrewPath
          )
          return .successWithoutResult(standardOutput: output.combinedOutput)
        } catch {
          AppLog.error(
            .plugins, "[Brew] command failed title=\(title) error=\(error.localizedDescription)")
          return .failure(message: error.localizedDescription)
        }
      }
    )
  }

  private var title: String { "\(command.titleVerb) \(package.packageName)" }

  private var arguments: [String] {
    package.kind == .cask
      ? [command.brewArgument, "--cask", package.packageName]
      : [command.brewArgument, package.packageName]
  }
}

private enum BrewCommand {
  case install
  case uninstall
  case upgrade

  var brewArgument: String {
    switch self {
    case .install: "install"
    case .uninstall: "uninstall"
    case .upgrade: "upgrade"
    }
  }

  var titleVerb: String {
    switch self {
    case .install: "Installing"
    case .uninstall: "Uninstalling"
    case .upgrade: "Upgrading"
    }
  }
}

extension BrewProcessOutput {
  fileprivate var combinedOutput: String? {
    let output = [stdout, stderr]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    return output.isEmpty ? nil : output
  }
}

/// Homebrew's verbs. The packages themselves are items in `BrewCatalog`.
public final class BrewActionCatalog: NSObject, ActionCatalog {
  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = BrewActionsCatalog.actions()

  public required init(definition: ActionCatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    super.init()
  }
}
