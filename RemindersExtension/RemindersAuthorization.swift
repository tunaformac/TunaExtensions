@preconcurrency import EventKit
import Foundation

protocol RemindersAuthorizationProviding {
  func ensureAuthorization(using store: EKEventStore) async -> Bool
}

struct RemindersAuthorization: RemindersAuthorizationProviding {
  func ensureAuthorization(using store: EKEventStore) async -> Bool {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess:
      return true
    case .notDetermined:
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return false
      }
      return await withCheckedContinuation { continuation in
        store.requestFullAccessToReminders { granted, _ in
          continuation.resume(returning: granted)
        }
      }
    case .restricted, .denied, .writeOnly:
      return false
    @unknown default:
      return false
    }
  }
}
