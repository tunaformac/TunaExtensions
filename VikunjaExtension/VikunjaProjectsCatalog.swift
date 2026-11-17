import Foundation
import TunaKit

/// Source catalog of Vikunja projects. Projects are indexed (so they can be action targets and,
/// if the user enables global scope, searched directly) and browsable into their open tasks.
public final class VikunjaProjectsCatalog: Catalog, RescanSchedulingCatalog,
  StartupScanningCatalog, RetainedCatalogStateReleasing,
  CatalogSortingProviding, CatalogResultsSortModeProviding
{
  public let identifier: String
  public let name: String
  public let scansOnStartup = false
  public var sortOptions: [CatalogSortOption] { VikunjaSort.options }
  public var defaultSortOptionID: String { VikunjaSort.dueOptionID }
  public func resultsSortMode(forSortOptionID sortOptionID: String) -> ResultsSortMode? {
    sortOptionID == VikunjaSort.dueOptionID ? .time : nil
  }
  public var rescanHandler: (() -> Void)?

  private let projectsStore = LockedValue<[VikunjaProjectItem]>([])
  private let topLevelStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let deferredLoadState = DeferredCatalogLoadState()
  private var changeObserver: NSObjectProtocol?

  private lazy var rootItem = BrowseCatalogItem(
    title: "Vikunja Projects",
    id: VikunjaExtension.projectsCatalogIdentifier,
    detail: "Browse projects and their open tasks",
    catalogIcon: .init(symbolName: "folder", color: .blue),
    childrenProvider: { [weak self] in self?.browseChildren() ?? [] }
  )

  public var objects: [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return message }
    return [rootItem] + projectsStore.readValue { $0 }
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    changeObserver = NotificationCenter.default.addObserver(
      forName: VikunjaDataDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.projectsStore.readValue { $0 }.forEach { $0.resetChildren() }
        VikunjaCatalogSupport.postScanFinished(identifier: self.identifier)
      }
    }
  }

  deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
  }

  public func releaseRetainedState() {
    projectsStore.value = []
    topLevelStore.value = []
    messageStore.value = nil
    deferredLoadState.reset()
  }

  public func scan() async {
    defer { deferredLoadState.markLoadCompleted() }
    let connections = VikunjaCatalogSupport.connections()
    guard !connections.isEmpty else {
      projectsStore.value = []
      topLevelStore.value = []
      messageStore.value = [VikunjaCatalogSupport.authRequiredItem()]
      VikunjaCatalogSupport.postScanFinished(identifier: identifier)
      return
    }

    await VikunjaProjectCache.shared.invalidate()
    let results = await VikunjaCatalogSupport.loadPerConnection(connections) { connection in
      let client = try VikunjaAPIClient(connection: connection)
      let projects = try await VikunjaProjectCache.shared.projects(for: connection, client: client)
      return (projects: projects, server: client.server)
    }

    if results.count == 1, let first = results.first, case .failure(let error) = first.payload {
      projectsStore.value = []
      topLevelStore.value = []
      messageStore.value = [VikunjaCatalogSupport.errorItem(error)]
      VikunjaCatalogSupport.postScanFinished(identifier: identifier)
      return
    }

    var allItems: [VikunjaProjectItem] = []
    var topLevel: [CatalogItem] = []
    for result in results {
      switch result.payload {
      case .success(let payload):
        let (items, roots) = Self.makeProjectItems(
          payload.projects,
          connection: result.connection,
          server: payload.server,
          catalogIdentifier: identifier
        )
        allItems.append(contentsOf: items)
        if results.count == 1 {
          topLevel.append(contentsOf: roots)
        } else {
          topLevel.append(
            VikunjaSectionItem(
              title: result.connection.displayName,
              id: "vikunja.projects.connection.\(result.offset)",
              detail: roots.count == 1 ? "1 project" : "\(roots.count) projects",
              symbolName: "folder",
              iconColor: .blue,
              children: roots,
              sortOrder: result.offset
            ))
        }
      case .failure(let error):
        // Keep healthy connections browsable; the failing one shows its error in place.
        topLevel.append(
          VikunjaSectionItem(
            title: result.connection.displayName,
            id: "vikunja.projects.connection.\(result.offset)",
            detail: "Couldn’t load projects",
            symbolName: "folder",
            iconColor: .blue,
            children: [VikunjaCatalogSupport.errorItem(error)],
            sortOrder: result.offset
          ))
      }
    }

    projectsStore.value = allItems
    topLevelStore.value = topLevel
    messageStore.value = nil

    VikunjaCatalogSupport.postScanFinished(identifier: identifier)
  }

  private func browseChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return message }

    deferredLoadState.requestLoadIfNeeded { [weak self] in self?.rescanHandler?() }

    let roots = topLevelStore.readValue { $0 }
    if !roots.isEmpty { return roots }
    if deferredLoadState.didCompleteLoad {
      return [
        VikunjaCatalogSupport.emptyItem(
          title: "No projects", message: "Create a project in Vikunja to see it here.")
      ]
    }
    return [VikunjaCatalogSupport.loadingItem("Vikunja projects")]
  }

  /// Builds every project item (flat) plus the top-level roots, wiring child projects into
  /// their parents so browsing follows Vikunja's hierarchy.
  nonisolated static func makeProjectItems(
    _ projects: [VikunjaProject],
    connection: VikunjaConnection,
    server: VikunjaServerConfiguration,
    catalogIdentifier: String,
    idPrefix: String = VikunjaProjectItem.defaultIDPrefix
  ) -> (all: [VikunjaProjectItem], roots: [CatalogItem]) {
    let sorted = projects.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    var built: [Int: VikunjaProjectItem] = [:]

    func build(_ project: VikunjaProject, depth: Int) -> VikunjaProjectItem {
      if let existing = built[project.id] { return existing }
      let children: [CatalogItem] =
        depth < 8
        ? sorted.filter { $0.parentProjectID == project.id && $0.id != project.id }
          .map { build($0, depth: depth + 1) }
        : []
      let item = VikunjaProjectItem(
        project: project,
        connection: connection,
        projectPath: VikunjaCatalogSupport.projectPath(project, in: projects),
        url: server.projectURL(id: project.id),
        catalogIdentifier: catalogIdentifier,
        childProjects: children,
        idPrefix: idPrefix
      )
      built[project.id] = item
      return item
    }

    let knownIDs = Set(projects.map(\.id))
    let roots = sorted
      .filter { $0.parentProjectID <= 0 || !knownIDs.contains($0.parentProjectID) }
      .map { build($0, depth: 0) }
    let all = sorted.map { build($0, depth: 0) }
    return (all, roots)
  }
}
