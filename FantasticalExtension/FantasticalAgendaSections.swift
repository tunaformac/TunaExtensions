import AppKit
import Foundation
import TunaKit

/// The browse groups under the Fantastical root. Each one is a date window the helper
/// understands; Tasks narrows to task calendars.
enum FantasticalAgendaRange: CaseIterable, Sendable {
  case today, tomorrow, thisWeek, next7Days, thisMonth, thisQuarter, thisYear, tasks

  var title: String {
    switch self {
    case .today: return "Today"
    case .tomorrow: return "Tomorrow"
    case .thisWeek: return "This Week"
    case .next7Days: return "Next 7 Days"
    case .thisMonth: return "This Month"
    case .thisQuarter: return "This Quarter"
    case .thisYear: return "This Year"
    case .tasks: return "Tasks"
    }
  }

  var symbolName: String {
    switch self {
    case .today: return "sun.max"
    case .tomorrow: return "sunrise"
    case .thisWeek, .next7Days: return "calendar"
    case .thisMonth: return "calendar.badge.clock"
    case .thisQuarter: return "square.grid.2x2"
    case .thisYear: return "calendar.circle"
    case .tasks: return "checklist"
    }
  }

  var iconColor: CatalogIconColor {
    switch self {
    case .today: return .orange
    case .tomorrow: return .yellow
    case .thisWeek, .next7Days: return .red
    case .thisMonth: return .purple
    case .thisQuarter, .thisYear: return .gray
    case .tasks: return .blue
    }
  }

  var tasksOnly: Bool { self == .tasks }

  func interval(now: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
    let day = calendar.startOfDay(for: now)
    func days(_ n: Int, from start: Date) -> DateInterval {
      DateInterval(start: start, end: calendar.date(byAdding: .day, value: n, to: start) ?? start)
    }
    switch self {
    case .today: return days(1, from: day)
    case .tomorrow: return days(1, from: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now) ?? days(7, from: day)
    case .next7Days: return days(7, from: day)
    case .thisMonth: return calendar.dateInterval(of: .month, for: now) ?? days(30, from: day)
    case .thisQuarter: return calendar.dateInterval(of: .quarter, for: now) ?? days(90, from: day)
    case .thisYear: return calendar.dateInterval(of: .year, for: now) ?? days(365, from: day)
    case .tasks: return days(30, from: day)
    }
  }

  /// The helper wants inclusive plain-language dates, so the exclusive end steps back a day.
  func when(now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
    let interval = interval(now: now, calendar: calendar)
    let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
    if calendar.isDate(interval.start, inSameDayAs: lastDay) {
      return FantasticalWhen.day(interval.start, calendar: calendar)
    }
    return FantasticalWhen.range(from: interval.start, to: lastDay, calendar: calendar)
  }
}

/// A group that fetches its events and tasks the first time it is browsed.
final class FantasticalRangeSectionItem: CatalogEntity, CatalogHierarchyNode, @unchecked Sendable {
  private let symbolName: String
  private let iconColor: CatalogIconColor
  private let catalogIdentifier: String
  private let loader: @Sendable () async throws -> [CatalogItem]
  private let childrenStore = LockedValue<[CatalogItem]>([])
  private let countStore = LockedValue<Int?>(nil)
  private let loadState = DeferredCatalogLoadState()
  private let loadTask = LockedValue<Task<Void, Never>?>(nil)

  init(
    title: String, id: String, symbolName: String, iconColor: CatalogIconColor,
    catalogIdentifier: String, loader: @escaping @Sendable () async throws -> [CatalogItem]
  ) {
    self.symbolName = symbolName
    self.iconColor = iconColor
    self.catalogIdentifier = catalogIdentifier
    self.loader = loader
    super.init(id: id, title: title, path: nil)
    typeID = .searchCatalogEntry
  }

  override var detail: String? {
    countStore.readValue { $0 }.map(FantasticalAgendaSupport.count) ?? "Browse to load"
  }

  func hierarchyChildren() -> [CatalogItem] {
    loadState.requestLoadIfNeeded { [weak self] in self?.load() }
    let children = childrenStore.readValue { $0 }
    if !children.isEmpty || loadState.didCompleteLoad { return children }
    return [CatalogLoadingItem(title: "Loading \(title)", message: "Asking Fantastical.")]
  }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .catalogIcon(symbolName: symbolName, color: iconColor, maxDimension: maxDimension)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  private func load() {
    loadTask.withValue { task in
      guard task == nil else { return }
      task = Task { [weak self] in
        guard let self else { return }
        do {
          let items = try await loader()
          countStore.value = items.count
          childrenStore.value = items.isEmpty
            ? [
              FantasticalAgendaSupport.messageItem(
                title: "Nothing here", message: "No events or tasks in \(title).",
                symbolName: symbolName, tint: .secondaryLabelColor)
            ]
            : items
        } catch {
          childrenStore.value = [FantasticalAgendaSupport.errorItem(error)]
        }
        loadState.markLoadCompleted()
        loadTask.value = nil
        FantasticalAgendaSupport.postScanFinished(identifier: catalogIdentifier)
      }
    }
  }
}
