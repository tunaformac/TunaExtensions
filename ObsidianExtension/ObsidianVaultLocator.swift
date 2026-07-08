import Foundation

enum ObsidianVaultLocator {
  struct Vault: Equatable, Sendable {
    let name: String
    let url: URL
  }

  enum LocatorError: Error, LocalizedError {
    case obsidianConfigMissing
    case invalidConfigData
    case noVaultsDetected

    var errorDescription: String? {
      switch self {
      case .obsidianConfigMissing:
        return "Obsidian config not found"
      case .invalidConfigData:
        return "Invalid Obsidian config"
      case .noVaultsDetected:
        return "No Obsidian vaults found"
      }
    }
  }

  static func locateVaults(
    fileManager: FileManager = .default
  ) -> Result<[Vault], LocatorError> {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let configURL =
      base
      .appendingPathComponent("obsidian", isDirectory: true)
      .appendingPathComponent("obsidian.json")

    guard fileManager.fileExists(atPath: configURL.path) else {
      return .failure(.obsidianConfigMissing)
    }

    let data: Data
    do {
      data = try Data(contentsOf: configURL)
    } catch {
      return .failure(.invalidConfigData)
    }

    let vaults = parseVaults(from: data)
    guard !vaults.isEmpty else {
      return .failure(.noVaultsDetected)
    }
    return .success(vaults)
  }

  static func parseVaults(from data: Data) -> [Vault] {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let vaults = json["vaults"] as? [String: Any]
    else { return [] }

    var results: [Vault] = []

    for (_, rawVault) in vaults {
      guard let vaultDict = rawVault as? [String: Any] else { continue }
      guard let path = vaultDict["path"] as? String else { continue }
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      let url = URL(fileURLWithPath: trimmed, isDirectory: true)
      let name = url.lastPathComponent
      guard !name.isEmpty else { continue }

      results.append(Vault(name: name, url: url))
    }

    return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
