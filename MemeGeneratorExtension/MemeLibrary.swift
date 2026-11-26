import Foundation
import TunaKit

extension Notification.Name {
  /// Posted after favorites change or a background refresh replaces cached templates.
  static let memeTemplatesDidChange = Notification.Name("com.tuna.meme-generator.templates-did-change")
  /// Posted after a fetch writes a template list, so the template source picks it up from the cache.
  static let memeTemplateCacheDidUpdate = Notification.Name(
    "com.tuna.meme-generator.template-cache-did-update")
}

/// Template lists are cached on disk indefinitely so the catalog works offline and starts instantly.
/// A cache older than `refreshInterval` is still used, and refreshed once in the background.
final class MemeTemplateLibrary: @unchecked Sendable {
  struct CacheFile: Codable, Sendable {
    let fetchedAt: Date
    let templates: [MemeTemplate]
  }

  struct LoadResult: Sendable {
    var templates: [MemeTemplate] = []
    var failures: [MemeProvider: String] = [:]
  }

  static let bundleIdentifier = "com.brnbw.tuna.plugins.memegenerator"

  /// Everything here is regenerable, so it lives in Caches (not backed up), in a bundle-ID folder.
  static let dataDirectory = RuntimeEnvironment.cachesDirectory()
    .appending(path: bundleIdentifier, directoryHint: .isDirectory)

  static let live = MemeTemplateLibrary(client: .live, directory: dataDirectory)

  static let refreshInterval: TimeInterval = 24 * 60 * 60

  private let client: MemeAPIClient
  private let directory: URL
  private let now: @Sendable () -> Date
  private let memory = LockedValue<[MemeProvider: CacheFile]>([:])
  private let refreshing = LockedValue<Set<MemeProvider>>([])

  init(client: MemeAPIClient, directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.client = client
    self.directory = directory
    self.now = now
  }

  func cacheURL(for provider: MemeProvider) -> URL {
    directory.appending(path: "templates-\(provider.rawValue).json")
  }

  /// Cached templates only: no network, no background refresh. Safe to call from a launch scan.
  func cachedTemplates(providers: [MemeProvider]) -> LoadResult {
    LoadResult(templates: providers.flatMap { cached($0)?.templates ?? [] })
  }

  /// Returns cached templates immediately; fetches only providers with no cache at all.
  /// Call this only on first use (browsing Make Meme), never from a launch scan.
  /// Stale caches trigger one background refresh that posts `.memeTemplatesDidChange`.
  func load(providers: [MemeProvider]) async -> LoadResult {
    var result = LoadResult()
    for provider in providers {
      if let cache = cached(provider) {
        result.templates += cache.templates
        if now().timeIntervalSince(cache.fetchedAt) > Self.refreshInterval {
          refreshInBackground(provider)
        }
        continue
      }
      do {
        result.templates += try await refresh(provider)
      } catch {
        result.failures[provider] = error.localizedDescription
      }
    }
    return result
  }

  @discardableResult
  func refresh(_ provider: MemeProvider) async throws -> [MemeTemplate] {
    let templates = try await client.templates(from: provider)
    guard !templates.isEmpty else { throw MemeError.invalidResponse(provider) }
    let cache = CacheFile(fetchedAt: now(), templates: templates)
    memory.withValue { $0[provider] = cache }
    save(cache, for: provider)
    await MainActor.run {
      NotificationCenter.default.post(name: .memeTemplateCacheDidUpdate, object: nil)
    }
    return templates
  }

  func cached(_ provider: MemeProvider) -> CacheFile? {
    if let cache = memory.readValue({ $0[provider] }) { return cache }
    guard let data = try? Data(contentsOf: cacheURL(for: provider)),
      let cache = try? Self.decoder.decode(CacheFile.self, from: data)
    else { return nil }
    memory.withValue { $0[provider] = cache }
    return cache
  }

  private func refreshInBackground(_ provider: MemeProvider) {
    let shouldStart = refreshing.withValue { $0.insert(provider).inserted }
    guard shouldStart else { return }
    Task.detached(priority: .utility) { [self] in
      defer { _ = refreshing.withValue { $0.remove(provider) } }
      do {
        try await refresh(provider)
        await MainActor.run {
          NotificationCenter.default.post(name: .memeTemplatesDidChange, object: nil)
        }
      } catch {
        AppLog.warning(
          .extensions,
          "Meme Generator kept cached \(provider.displayName) templates: \(error.localizedDescription)"
        )
      }
    }
  }

  private func save(_ cache: CacheFile, for provider: MemeProvider) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Self.encoder.encode(cache).write(to: cacheURL(for: provider), options: .atomic)
    } catch {
      AppLog.warning(.extensions, "Meme Generator could not save its template cache: \(error)")
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// Where favorites are kept: Tuna's defaults in the app, an in-memory store in tests (so tests never
/// write to `~/Library/Preferences`).
protocol MemeFavoritesStore: AnyObject {
  func stringArray(forKey key: String) -> [String]?
  func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: MemeFavoritesStore {}

/// Favorite template keys, stored in Tuna's defaults. Favorites always sort first.
struct MemeFavorites: @unchecked Sendable {
  static let live = MemeFavorites(defaults: UserDefaults.standard)
  static let defaultsKey = "com.tuna.meme-generator.favorites"

  let defaults: MemeFavoritesStore

  var keys: [String] { defaults.stringArray(forKey: Self.defaultsKey) ?? [] }

  func contains(_ template: MemeTemplate) -> Bool { keys.contains(template.key) }

  func set(_ template: MemeTemplate, favorite: Bool) {
    var current = keys.filter { $0 != template.key }
    if favorite { current.append(template.key) }
    defaults.set(current, forKey: Self.defaultsKey)
  }

  /// Favorites first (alphabetically), then everything else in provider order.
  func ordered(_ templates: [MemeTemplate]) -> [MemeTemplate] {
    let favoriteKeys = Set(keys)
    var seen = Set<String>()
    let unique = templates.filter { seen.insert($0.key).inserted }
    let favorites = unique.filter { favoriteKeys.contains($0.key) }
      .sorted { lhs, rhs in
        // Strict ordering: name first, then the provider-qualified key as a deterministic tie-break.
        switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.key < rhs.key
        }
      }
    return favorites + unique.filter { !favoriteKeys.contains($0.key) }
  }
}
