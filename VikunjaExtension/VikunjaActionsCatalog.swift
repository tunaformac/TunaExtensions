import AppKit
import Foundation
import TunaKit

public final class VikunjaActionsCatalog: ActionCatalog {
  nonisolated static let openTaskActionID = "open-task"
  nonisolated static let openProjectActionID = "open-project"
  nonisolated static let markDoneActionID = "mark-done"
  nonisolated static let addTaskActionID = "add-task"
  nonisolated static let addTaskToProjectActionID = "add-task-to-project"
  nonisolated static let toActionID = "to"

  public let identifier: String
  public let name: String

  public private(set) lazy var actions: [CatalogAction] = Self.makeActions()

  public required init(definition: ActionCatalogDefinition) {
    identifier = definition.identifier
    name = definition.name
  }

  static func makeActions() -> [CatalogAction] {
    let openTask = PredicateAwareAction(id: openTaskActionID, title: "Open in Vikunja") {
      subject, _ in
      VikunjaActions.open(subject)
    }
    openTask.systemSymbolName = "arrow.up.right.square"
    openTask.supportedSubjectTypes = [.vikunjaTask]
    openTask.subjectPredicate = { $0 is VikunjaTaskItem }

    let openProject = PredicateAwareAction(id: openProjectActionID, title: "Open in Vikunja") {
      subject, _ in
      VikunjaActions.open(subject)
    }
    openProject.systemSymbolName = "arrow.up.right.square"
    openProject.supportedSubjectTypes = [.vikunjaProject]
    openProject.subjectPredicate = { $0 is VikunjaProjectItem }

    let markDone = PredicateAwareAction(id: markDoneActionID, title: "Mark Done") { subject, _ in
      await VikunjaActions.markDone([subject])
    }
    markDone.batchCallback = { subjects, _ in
      await VikunjaActions.markDone(subjects)
    }
    markDone.systemSymbolName = "checkmark.circle"
    markDone.supportedSubjectTypes = [.vikunjaTask]
    markDone.subjectPredicate = { subject in
      guard let item = subject as? VikunjaTaskItem else { return false }
      return !item.task.done
    }

    let addTask = PredicateAwareAction(id: addTaskActionID, title: "Add to Vikunja") {
      subject, _ in
      await VikunjaActions.createTasks(titles: VikunjaActions.titles(from: [subject]), project: nil)
    }
    addTask.batchCallback = { subjects, _ in
      await VikunjaActions.createTasks(titles: VikunjaActions.titles(from: subjects), project: nil)
    }
    addTask.systemSymbolName = "plus.circle"
    addTask.supportedSubjectTypes = [.textSnippet]
    addTask.subjectPredicate = { VikunjaActions.title(from: $0) != nil }

    let addToProject = PredicateAwareAction(
      id: addTaskToProjectActionID, title: "Add to Vikunja Project"
    ) { subject, target in
      guard let project = target as? VikunjaProjectItem else {
        return .failure("Choose a Vikunja project")
      }
      return await VikunjaActions.createTasks(
        titles: VikunjaActions.titles(from: [subject]), project: project)
    }
    addToProject.batchCallback = { subjects, target in
      guard let project = target as? VikunjaProjectItem else {
        return .failure("Choose a Vikunja project")
      }
      return await VikunjaActions.createTasks(
        titles: VikunjaActions.titles(from: subjects), project: project)
    }
    addToProject.targetRequirement = .required
    addToProject.systemSymbolName = "folder.badge.plus"
    addToProject.supportedSubjectTypes = [.textSnippet]
    addToProject.allowedTargetTypes = [.vikunjaProject]
    addToProject.targetSearchScope = .catalogs(
      [VikunjaExtension.projectsCatalogIdentifier], preparation: .refresh)
    addToProject.subjectPredicate = { VikunjaActions.title(from: $0) != nil }
    addToProject.targetPredicate = { $0 is VikunjaProjectItem }

    let toAction = PredicateAwareAction(id: toActionID, title: "To...") { subject, target in
      guard subject is VikunjaNewTaskItem else {
        return .failure("Select New Vikunja Task first")
      }
      guard let title = VikunjaActions.title(from: target) else {
        return .failure("Type a task title")
      }
      return await VikunjaActions.createTasks(titles: [title], project: nil)
    }
    toAction.targetRequirement = .required
    toAction.systemSymbolName = "plus.circle"
    toAction.supportedSubjectTypes = [.searchCatalogEntry]
    toAction.allowedTargetTypes = [.textSnippet]
    toAction.subjectPredicate = { $0 is VikunjaNewTaskItem }
    toAction.targetPredicate = { VikunjaActions.title(from: $0) != nil }

    return [openTask, openProject, markDone, addTask, addToProject, toAction]
  }
}

enum VikunjaActions {
  static func open(_ subject: CatalogItem) -> ActionResult {
    guard let entity = subject as? CatalogEntity, let path = entity.path, let url = URL(string: path)
    else {
      return .failure("No Vikunja link for \(subject.title)")
    }
    NSWorkspace.shared.open(url)
    return .success
  }

  static func title(from item: CatalogItem?) -> String? {
    guard let item else { return nil }
    let value = item.textInputValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static func titles(from items: [CatalogItem]) -> [String] {
    items.compactMap(title(from:))
  }

  static func markDone(_ subjects: [CatalogItem]) async -> ActionResult {
    let items = subjects.compactMap { $0 as? VikunjaTaskItem }
    guard !items.isEmpty else { return .failure("No Vikunja task selected") }

    var failures: [String] = []
    for item in items {
      guard let connection = VikunjaCatalogSupport.connection(id: item.connectionID) else {
        failures.append("\(item.task.title): connection removed")
        continue
      }
      do {
        let client = try VikunjaAPIClient(connection: connection)
        _ = try await client.setTaskDone(id: item.task.id, done: true)
      } catch {
        failures.append("\(item.task.title): \(error.localizedDescription)")
      }
    }

    if failures.count < items.count {
      VikunjaCatalogSupport.postDataDidChange()
    }
    guard failures.isEmpty else {
      return .failure(failures.joined(separator: "\n"))
    }
    return .success
  }

  /// Creates one task per title. `project` nil means the default project from settings on the
  /// default connection.
  static func createTasks(titles: [String], project: VikunjaProjectItem?) async -> ActionResult {
    guard !titles.isEmpty else { return .failure("Type a task title") }

    let connection: VikunjaConnection
    let projectID: Int
    let projectTitle: String
    do {
      if let project {
        connection = project.connection
        projectID = project.project.id
        projectTitle = project.project.title
      } else {
        guard let defaultConnection = VikunjaCatalogSupport.defaultConnection() else {
          throw VikunjaAPIError.missingConnection
        }
        connection = defaultConnection
        let client = try VikunjaAPIClient(connection: connection)
        let projects = try await VikunjaProjectCache.shared.projects(for: connection, client: client)
        let preference = VikunjaSettings.defaultProject
        guard
          let resolved = VikunjaCatalogSupport.resolveDefaultProject(
            projects, preference: preference)
        else {
          throw VikunjaAPIError.projectNotFound(preference)
        }
        projectID = resolved.id
        projectTitle = resolved.title
      }
    } catch {
      return .failure(error.localizedDescription)
    }

    var failures: [String] = []
    var created = 0
    do {
      let client = try VikunjaAPIClient(connection: connection)
      for title in titles {
        do {
          _ = try await client.createTask(title: title, projectID: projectID)
          created += 1
        } catch {
          failures.append("\(title): \(error.localizedDescription)")
        }
      }
    } catch {
      return .failure(error.localizedDescription)
    }

    if created > 0 {
      VikunjaCatalogSupport.postDataDidChange()
    }
    guard failures.isEmpty else {
      return .failure("Could not add to \(projectTitle):\n" + failures.joined(separator: "\n"))
    }
    return .success
  }
}
