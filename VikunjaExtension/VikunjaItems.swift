import AppKit
import Foundation
import TunaKit

/// One open (or just-completed) Vikunja task. A plain entity (so Tuna shows its icon card);
/// "Open in Vikunja" opens the link and Copy yields it.
final class VikunjaTaskItem: CatalogEntity, TimestampedCatalogItem, ScoredCatalogItem,
  CopyRepresentationProviding, @unchecked Sendable
{
  let task: VikunjaTask
  let connectionID: String
  let projectTitle: String?
  let capturedAtDate: Date
  private let detailText: String

  /// Copy to Clipboard yields the task link.
  var copyRepresentation: String? { path }

  /// Score ordering: soonest due first, undated last (ties broken by priority).
  var sortScore: Double { VikunjaSort.score(forDueDate: task.dueDate, priority: task.priority) }

  init(
    task: VikunjaTask,
    connectionID: String,
    projectTitle: String?,
    url: URL,
    detail: String
  ) {
    self.task = task
    self.connectionID = connectionID
    self.projectTitle = projectTitle
    self.detailText = detail
    self.capturedAtDate = VikunjaSort.timestamp(forDueDate: task.dueDate)
    super.init(
      id: "vikunja.task.\(connectionID).\(task.id)",
      title: task.title,
      path: url.absoluteString
    )
    typeID = .vikunjaTask
  }

  override var detail: String? { detailText }

  override var searchKeys: [String] {
    var keys = [title]
    if let projectTitle, !projectTitle.isEmpty { keys.append(projectTitle) }
    keys.append(contentsOf: task.labels.map(\.title))
    if !task.identifier.isEmpty { keys.append(task.identifier) }
    return keys
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    if task.done {
      return .systemSymbol("checkmark.circle.fill", tintColor: .systemGreen)
    }
    if let dueDate = task.dueDate, dueDate < Date(),
      !Calendar.autoupdatingCurrent.isDateInToday(dueDate)
    {
      return .systemSymbol("exclamationmark.circle", tintColor: .systemRed)
    }
    if task.priority >= 4 {
      return .systemSymbol("exclamationmark.circle", tintColor: .systemOrange)
    }
    if task.priority == 3 {
      return .systemSymbol("circle", tintColor: .systemOrange)
    }
    return .systemSymbol("circle", tintColor: .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

/// A Vikunja project. Browsable: children are its sub-projects followed by its open tasks,
/// loaded on first browse. Also the target of “Add to Vikunja Project”.
final class VikunjaProjectItem: CatalogEntity, CatalogHierarchyNode, CopyRepresentationProviding,
  @unchecked Sendable
{
  static let defaultIDPrefix = "vikunja.project"

  /// Copy to Clipboard yields the project link.
  var copyRepresentation: String? { path }

  let project: VikunjaProject
  let connection: VikunjaConnection
  let projectPath: String
  private let iconColor: CatalogIconColor
  private let catalogIdentifier: String
  private let childProjects: [CatalogItem]
  private let childrenStore = LockedValue<[CatalogItem]>([])
  private let messageStore = LockedValue<[CatalogItem]?>(nil)
  private let loadState = DeferredCatalogLoadState()
  private let loadTask = LockedValue<Task<Void, Never>?>(nil)

  init(
    project: VikunjaProject,
    connection: VikunjaConnection,
    projectPath: String,
    url: URL,
    catalogIdentifier: String,
    childProjects: [CatalogItem],
    idPrefix: String = VikunjaProjectItem.defaultIDPrefix
  ) {
    self.project = project
    self.connection = connection
    self.projectPath = projectPath
    self.iconColor = VikunjaCatalogSupport.iconColor(forHex: project.hexColor)
    self.catalogIdentifier = catalogIdentifier
    self.childProjects = childProjects
    super.init(
      id: "\(idPrefix).\(connection.id).\(project.id)",
      title: project.title,
      path: url.absoluteString
    )
    typeID = .vikunjaProject
  }

  override var detail: String? {
    var parts: [String] = []
    if projectPath != project.title {
      parts.append(projectPath)
    } else {
      parts.append("Vikunja project")
    }
    if project.isFavorite { parts.append("Favorite") }
    return parts.joined(separator: " · ")
  }

  override var searchKeys: [String] {
    [title, projectPath]
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: "folder", color: iconColor, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  func hierarchyChildren() -> [CatalogItem] {
    if let message = messageStore.readValue({ $0 }) { return childProjects + message }

    loadState.requestLoadIfNeeded { [weak self] in self?.loadTasks() }
    let tasks = childrenStore.readValue { $0 }
    if !tasks.isEmpty || loadState.didCompleteLoad { return childProjects + tasks }
    return childProjects + [VikunjaCatalogSupport.loadingItem(project.title)]
  }

  /// Drops cached tasks so the next browse refetches them.
  func resetChildren() {
    loadTask.withValue { task in
      task?.cancel()
      task = nil
    }
    childrenStore.value = []
    messageStore.value = nil
    loadState.reset()
  }

  private func loadTasks() {
    loadTask.withValue { task in
      guard task == nil else { return }
      let connection = connection
      let project = project
      task = Task { [weak self] in
        guard let self else { return }
        do {
          let client = try VikunjaAPIClient(connection: connection)
          let listing = try await client.fetchOpenTasks(projectID: project.id)
          let tasks = VikunjaCatalogSupport.sortedByDue(listing.tasks)
          if Task.isCancelled { return }
          let truncated: [CatalogItem] =
            listing.isTruncated
            ? [VikunjaCatalogSupport.truncatedItem(shown: tasks.count, searching: false)] : []
          childrenStore.value = tasks.isEmpty
            ? [
              VikunjaCatalogSupport.emptyItem(
                title: "No open tasks", message: "Every task in \(project.title) is done.")
            ]
            : tasks.map {
              VikunjaCatalogSupport.makeTaskItem(
                $0, projectTitle: nil, connection: connection, totalConnections: 1,
                server: client.server)
            } + truncated
          messageStore.value = nil
        } catch {
          childrenStore.value = []
          messageStore.value = [VikunjaCatalogSupport.errorItem(error)]
        }
        loadState.markLoadCompleted()
        loadTask.value = nil
        VikunjaCatalogSupport.postScanFinished(identifier: catalogIdentifier)
      }
    }
  }
}

/// Grouping node used for due-date buckets and per-connection sections.
final class VikunjaSectionItem: CatalogEntity, CatalogHierarchyNode, TimestampedCatalogItem,
  ScoredCatalogItem, @unchecked Sendable
{
  private let children: [CatalogItem]
  private let symbolName: String
  private let iconColor: CatalogIconColor
  let sortOrder: Int
  let capturedAtDate: Date

  /// Sections outrank every task and keep their declared order.
  var sortScore: Double { VikunjaSort.sectionScoreBase - Double(max(0, min(sortOrder, 10_000))) }

  init(
    title: String,
    id: String,
    detail: String?,
    symbolName: String,
    iconColor: CatalogIconColor,
    children: [CatalogItem],
    sortOrder: Int
  ) {
    self.children = children
    self.symbolName = symbolName
    self.iconColor = iconColor
    self.sortOrder = sortOrder
    self.detailText = detail
    let normalized = max(0, min(sortOrder, 10_000))
    self.capturedAtDate = Date.distantFuture.addingTimeInterval(-Double(normalized))
    super.init(id: id, title: title, path: nil)
    typeID = .searchCatalogEntry
  }

  private let detailText: String?

  override var detail: String? { detailText }

  func hierarchyChildren() -> [CatalogItem] { children }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: symbolName, color: iconColor, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

/// Entry point for quick capture: select it, choose “To…”, and type the task title.
final class VikunjaNewTaskItem: CatalogEntity, @unchecked Sendable {
  static let identifier = "vikunja.new"

  init() {
    super.init(id: Self.identifier, title: "New Vikunja Task", path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    "Create a task in your default Vikunja project from typed text"
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol("plus.circle")
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }
}

extension VikunjaNewTaskItem: ActionFilteringProviding {
  func allowsAction(_ action: CatalogAction, catalogIdentifier: String?) -> Bool {
    guard catalogIdentifier == VikunjaExtension.actionsCatalogIdentifier else { return false }
    return action.id == VikunjaActionsCatalog.toActionID
  }
}

extension VikunjaCatalogSupport {
  static func makeTaskItem(
    _ task: VikunjaTask,
    projectTitle: String?,
    connection: VikunjaConnection,
    totalConnections: Int,
    server: VikunjaServerConfiguration
  ) -> VikunjaTaskItem {
    VikunjaTaskItem(
      task: task,
      connectionID: connection.id,
      projectTitle: projectTitle,
      url: server.taskURL(id: task.id),
      detail: taskDetail(
        task,
        projectTitle: projectTitle,
        connection: connection,
        totalConnections: totalConnections
      )
    )
  }
}
