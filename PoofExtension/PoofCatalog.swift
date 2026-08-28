import Foundation
import TunaKit

@MainActor
public final class PoofCatalog: Catalog, RescanSchedulingCatalog {
  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?
  public var objects: [CatalogItem] { snippetItems }

  private let fileManager: FileManager
  private let configDirectory: URL
  private var snippetItems: [CatalogItem] = []
  private var watchers: [DispatchSourceFileSystemObject] = []
  private var changeObserver: NSObjectProtocol?

  public required convenience init(definition: CatalogDefinition) {
    self.init(
      identifier: definition.identifier,
      name: definition.name,
      configDirectory: PoofConfig.directory()
    )
  }

  init(
    identifier: String,
    name: String = "Poof Snippets",
    configDirectory: URL,
    fileManager: FileManager = .default
  ) {
    self.identifier = identifier
    self.name = name
    self.configDirectory = configDirectory
    self.fileManager = fileManager
    changeObserver = NotificationCenter.default.addObserver(
      forName: .poofSnippetsChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rescanHandler?() }
    }
  }

  deinit {
    watchers.forEach { $0.cancel() }
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  public func scan() async {
    let records = PoofSnippetParser.activeRecords(in: configDirectory, fileManager: fileManager)
    snippetItems = records.map(PoofSnippetItem.init(record:))
    installWatchers()
  }

  private func installWatchers() {
    watchers.forEach { $0.cancel() }
    watchers = []

    var watchedURLs = Set(
      PoofSnippetParser.loadFiles(in: configDirectory, fileManager: fileManager).map(\.url)
    )
    watchedURLs.insert(nearestExistingDirectory(to: configDirectory))
    if let enumerator = fileManager.enumerator(
      at: configDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      for case let url as URL in enumerator
      where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        watchedURLs.insert(url)
      }
    }
    for url in watchedURLs {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .delete, .rename, .extend],
        queue: .main
      )
      source.setEventHandler {
        NotificationCenter.default.post(name: .poofSnippetsChanged, object: nil)
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      watchers.append(source)
    }
  }

  private func nearestExistingDirectory(to url: URL) -> URL {
    var candidate = url
    while !fileManager.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
      candidate.deleteLastPathComponent()
    }
    return candidate
  }
}

@MainActor
public final class PoofBrowseCatalog: Catalog, RescanSchedulingCatalog {
  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)?
  public var objects: [CatalogItem] { [libraryItem] }

  private let configDirectory: URL
  private let fileManager: FileManager
  private let libraryItem: PoofLibraryItem
  private var changeObserver: NSObjectProtocol?

  public required convenience init(definition: CatalogDefinition) {
    self.init(
      identifier: definition.identifier,
      name: definition.name,
      configDirectory: PoofConfig.directory()
    )
  }

  init(
    identifier: String,
    name: String = "Poof Snippets",
    configDirectory: URL,
    fileManager: FileManager = .default
  ) {
    self.identifier = identifier
    self.name = name
    self.configDirectory = configDirectory
    self.fileManager = fileManager
    self.libraryItem = PoofLibraryItem(directoryURL: configDirectory)
    changeObserver = NotificationCenter.default.addObserver(
      forName: .poofSnippetsChanged,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rescanHandler?() }
    }
  }

  deinit {
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  public func scan() async {
    libraryItem.snippets = PoofSnippetParser.activeRecords(
      in: configDirectory,
      fileManager: fileManager
    ).map(PoofSnippetItem.init(record:))
  }
}

extension Notification.Name {
  static let poofSnippetsChanged = Notification.Name("PoofExtension.snippetsChanged")
}
