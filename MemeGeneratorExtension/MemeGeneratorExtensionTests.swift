import AppKit
import Foundation
import Network
import TunaKit
import XCTest

@testable import TunaMemeGenerator

final class MemeGeneratorExtensionTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: "MemeGeneratorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    MockURLProtocol.requestHandler = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  // MARK: Declaration and grammar

  @MainActor
  func testDeclarationExposesTemplatesSourceBrowseRootAndActions() throws {
    let instance = try MemeGeneratorExtension(bundle: Bundle(for: MemeGeneratorExtension.self))
    let declaration = try XCTUnwrap(instance.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.catalogs.map(\.id), ["memes.templates", "memes.templates.browse"])
    XCTAssertEqual(declaration.catalogs[0].presentation, .source)
    XCTAssertEqual(declaration.catalogs[1].presentation, .browseRoot(contents: "memes.templates"))
    XCTAssertEqual(declaration.catalogs[0].initialGlobalScope, .none, "Templates stay out of search")
    XCTAssertEqual(declaration.catalogs[1].name, "Make Meme")
    XCTAssertTrue(declaration.catalogs.allSatisfy(\.enabledByDefault))
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["memes.actions"])
    XCTAssertEqual(declaration.settings.map(\.key), ["ImgflipUsername", "ImgflipPassword"])
    XCTAssertEqual(declaration.settings.map(\.type), [.string, .secret])
    XCTAssertEqual(declaration.typeRegistrations.map(\.typeID), [.memeTemplate, .memeImage])
    XCTAssertEqual(declaration.typeRegistrations[1].inheritsFrom, [.file])
    XCTAssertEqual(
      declaration.defaultActionRankings.first?.actions.map(\.actionID),
      ["make-meme", "add-favorite", "remove-favorite"])
  }

  @MainActor
  func testActionGrammar() throws {
    let catalog = MemeActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "memes.actions", name: "Meme Actions"))
    XCTAssertEqual(
      catalog.actions.map(\.id),
      ["make-meme", "add-favorite", "remove-favorite", "copy-image", "copy-url"])

    let make = catalog.actions[0]
    XCTAssertEqual(make.title, "Make Meme")
    XCTAssertEqual(make.targetRequirement, .optional)
    XCTAssertEqual(make.supportedSubjectTypes, [.memeTemplate])
    XCTAssertEqual(make.allowedTargetTypes, [.textSnippet])
    XCTAssertEqual(make.executionPolicy, .keepVisible)

    let item = MemeTemplateItem(Self.drake)
    XCTAssertEqual(make.targetTextSeedProvider?(item), "[Text 1] | [Text 2]")
    let predicate = try XCTUnwrap((make as? ActionPredicateProviding)?.targetPredicate)
    XCTAssertTrue(predicate(TextSnippetItem(text: "a | b")))
    XCTAssertFalse(predicate(TextSnippetItem(text: " | ")))

    XCTAssertEqual(catalog.actions[3].supportedSubjectTypes, [.memeImage])
    XCTAssertEqual(catalog.actions[4].supportedSubjectTypes, [.memeImage])
  }

  // MARK: Text and URLs

  func testTextSplitsIntoExactlyTheTemplateLineCount() {
    XCTAssertEqual(MemeText.lines(from: "top | bottom", lineCount: 2), ["top", "bottom"])
    XCTAssertEqual(MemeText.lines(from: "only top", lineCount: 2), ["only top", ""])
    XCTAssertEqual(MemeText.lines(from: "a|b|c|d", lineCount: 2), ["a", "b | c | d"])
    XCTAssertEqual(MemeText.lines(from: "first\nsecond", lineCount: 3), ["first", "second", ""])
    XCTAssertEqual(MemeText.lines(from: "| bottom only", lineCount: 2), ["", "bottom only"])
    XCTAssertEqual(MemeText.lines(from: "solo", lineCount: 0), ["solo"])
    XCTAssertFalse(MemeText.hasText("  |  \n "))
    XCTAssertTrue(MemeText.hasText("x"))
  }

  func testPlaceholdersSeedAndFallBackToExampleText() {
    XCTAssertEqual(MemeText.placeholders(lineCount: 1), ["[Text 1]"])
    XCTAssertEqual(MemeText.placeholders(lineCount: 3), ["[Text 1]", "[Text 2]", "[Text 3]"])
    XCTAssertTrue(MemeText.isPlaceholder("[text 2]"))
    XCTAssertTrue(MemeText.isPlaceholder("[Insert Bottom Text]"))
    XCTAssertFalse(MemeText.isPlaceholder("[Insert coin]"))
    XCTAssertFalse(MemeText.isPlaceholder("[Text me]"))

    // Untouched seed → the template's example; edited boxes are kept, untouched ones fall back.
    XCTAssertEqual(
      MemeText.resolvedLines(from: Self.drake.textSeed, template: Self.drake), ["Top", "Bottom"])
    XCTAssertEqual(
      MemeText.resolvedLines(from: "Tabs | [Text 2]", template: Self.drake),
      ["Tabs", "Bottom"])
    XCTAssertEqual(
      MemeText.resolvedLines(from: "[Text 1] | Spaces", template: Self.drake),
      ["Top", "Spaces"])
    XCTAssertEqual(
      MemeText.resolvedLines(from: "[Text 1] | b", template: Self.template("x", "X")),
      ["", "b"])
  }

  func testMemegenEscapesSpecialCharacters() {
    XCTAssertEqual(MemegenURLBuilder.escape("a_b-c d"), "a__b--c_d")
    XCTAssertEqual(MemegenURLBuilder.escape("why? 100% #1 a/b"), "why~q_100~p_~h1_a~sb")
    XCTAssertEqual(MemegenURLBuilder.escape(#"say "hi" <3 & \o/"#), "say_''hi''_~l3_~a_~bo~s")
  }

  func testMemegenImageURL() {
    XCTAssertEqual(
      MemegenURLBuilder.imageURL(templateID: "drake", lines: ["Writing tests", ""]).absoluteString,
      "https://api.memegen.link/images/drake/Writing_tests/_.png")
    XCTAssertEqual(
      MemegenURLBuilder.imageURL(templateID: "fry", lines: ["Not sure if café"]).absoluteString,
      "https://api.memegen.link/images/fry/Not_sure_if_caf%C3%A9.png")
    XCTAssertEqual(Self.drake.thumbnailURL.absoluteString, "https://api.memegen.link/images/drake.png?width=300")
  }

  func testImgflipCaptionRequestFormEncodesBoxes() throws {
    let client = MemeAPIClient(session: mockSession())
    let request = client.imgflipCaptionRequest(
      templateID: "181913649", lines: ["a & b", "c+d"],
      credentials: ImgflipCredentials(username: "me", password: "p@ss word"))
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://api.imgflip.com/caption_image")
    let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    XCTAssertEqual(
      body,
      "template_id=181913649&username=me&password=p%40ss%20word"
        + "&boxes%5B0%5D%5Btext%5D=a%20%26%20b&boxes%5B1%5D%5Btext%5D=c%2Bd")
  }

  // MARK: Providers

  func testDecodesMemegenTemplates() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.memegen.link/templates/")
      return Self.response(request, body: Self.memegenJSON)
    }
    let templates = try await MemeAPIClient(session: mockSession()).memegenTemplates()
    XCTAssertEqual(templates.map(\.key), ["memegen:drake", "memegen:fry"])
    XCTAssertEqual(templates[0].exampleLines, ["Top", "Bottom"])
    XCTAssertEqual(templates[1].lineCount, 2)
    XCTAssertEqual(templates[1].keywords, [])
  }

  func testDecodesImgflipTemplates() async throws {
    MockURLProtocol.requestHandler = { request in
      Self.response(request, body: Self.imgflipJSON)
    }
    let templates = try await MemeAPIClient(session: mockSession()).imgflipTemplates()
    XCTAssertEqual(templates.map(\.key), ["imgflip:181913649"])
    XCTAssertEqual(templates[0].lineCount, 2)
    XCTAssertEqual(templates[0].thumbnailURL, templates[0].blankURL)
  }

  func testImgflipErrorMessageIsSurfaced() async throws {
    MockURLProtocol.requestHandler = { request in
      Self.response(request, body: #"{"success":false,"error_message":"Invalid username/password"}"#)
    }
    do {
      _ = try await MemeAPIClient(session: mockSession()).generate(
        template: Self.imgflipDrake, lines: ["a", "b"],
        imgflipCredentials: ImgflipCredentials(username: "u", password: "p"))
      XCTFail("Expected an error")
    } catch {
      XCTAssertEqual(error as? MemeError, .provider(.imgflip, "Invalid username/password"))
    }
  }

  func testImgflipPasswordIsNeverForwardedByRedirects() async throws {
    // Two real loopback origins, through the real request path (`MemeAPIClient.generate` with the
    // live session): A answers the caption POST with a 307 to B, which would replay the body.
    let origin = try await LoopbackServer.start()
    let elsewhere = try await LoopbackServer.start()
    defer {
      origin.stop()
      elsewhere.stop()
    }
    elsewhere.respond = { _ in LoopbackServer.reply(status: 200, body: #"{"success":true}"#) }
    origin.respond = { _ in
      LoopbackServer.reply(
        status: 307, headers: ["Location": elsewhere.url.appending(path: "caption_image").absoluteString])
    }

    let client = MemeAPIClient(imgflipBaseURL: origin.url)
    do {
      _ = try await client.generate(
        template: Self.imgflipDrake, lines: ["a", "b"],
        imgflipCredentials: ImgflipCredentials(username: "me", password: "synthetic-secret"))
      XCTFail("Expected the redirect to be refused")
    } catch {
      XCTAssertEqual(error as? MemeError, .httpStatus(.imgflip, 307))
    }
    XCTAssertEqual(origin.requests.count, 1)
    XCTAssertTrue(origin.requests[0].contains("synthetic-secret"), "The password went to A only")
    XCTAssertTrue(elsewhere.requests.isEmpty, "B must never see the request")

    // Control: B is reachable, so the empty log above means the redirect was refused.
    _ = try await URLSession(configuration: .ephemeral).data(from: elsewhere.url)
    XCTAssertEqual(elsewhere.requests.count, 1)
  }

  func testImgflipRequiresCredentials() async {
    do {
      _ = try await MemeAPIClient(session: mockSession()).generate(
        template: Self.imgflipDrake, lines: ["a", "b"], imgflipCredentials: nil)
      XCTFail("Expected an error")
    } catch {
      XCTAssertEqual(error as? MemeError, .missingImgflipCredentials)
    }
  }

  // MARK: Cache

  func testFirstLoadFetchesAndCachesThenServesCacheOffline() async throws {
    var requests = 0
    MockURLProtocol.requestHandler = { request in
      requests += 1
      return Self.response(request, body: Self.memegenJSON)
    }
    let library = MemeTemplateLibrary(
      client: MemeAPIClient(session: mockSession()), directory: temporaryDirectory)
    let first = await library.load(providers: [.memegen])
    XCTAssertEqual(first.templates.count, 2)
    XCTAssertTrue(first.failures.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.cacheURL(for: .memegen).path))

    // A new library instance reads the disk cache and never touches the network.
    MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    let offline = MemeTemplateLibrary(
      client: MemeAPIClient(session: mockSession()), directory: temporaryDirectory)
    let second = await offline.load(providers: [.memegen])
    XCTAssertEqual(second.templates.map(\.key), first.templates.map(\.key))
    XCTAssertEqual(requests, 1)
  }

  func testStaleCacheIsServedWhileRefreshingInBackground() async throws {
    let old = MemeTemplateLibrary.CacheFile(
      fetchedAt: Date(timeIntervalSince1970: 0), templates: [Self.drake])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let library = MemeTemplateLibrary(
      client: MemeAPIClient(session: mockSession()), directory: temporaryDirectory)
    try encoder.encode(old).write(to: library.cacheURL(for: .memegen))

    let refreshed = expectation(forNotification: .memeTemplatesDidChange, object: nil)
    MockURLProtocol.requestHandler = { request in Self.response(request, body: Self.memegenJSON) }

    let result = await library.load(providers: [.memegen])
    XCTAssertEqual(result.templates.map(\.key), ["memegen:drake"])

    await fulfillment(of: [refreshed], timeout: 5)
    XCTAssertEqual(library.cached(.memegen)?.templates.count, 2)
  }

  func testCachesLiveInCachesDirectoryUnderTheBundleID() {
    let root = RuntimeEnvironment.cachesDirectory().standardizedFileURL.path
    let directory = MemeTemplateLibrary.dataDirectory.standardizedFileURL
    XCTAssertTrue(directory.path.hasPrefix(root + "/"), directory.path)
    XCTAssertEqual(directory.lastPathComponent, "com.brnbw.tuna.plugins.memegenerator")
    XCTAssertEqual(
      Bundle(for: MemeGeneratorExtension.self).bundleIdentifier,
      MemeTemplateLibrary.bundleIdentifier)
    XCTAssertTrue(
      MemeThumbnailCache.live.directory.standardizedFileURL.path.hasPrefix(directory.path + "/"))
  }

  @MainActor
  func testLaunchScanMakesNoRequestsUntilMakeMemeIsBrowsed() async throws {
    let log = RequestLog()
    MockURLProtocol.requestHandler = { request in
      log.append(request.url?.absoluteString ?? "")
      if request.url?.path() == "/templates/" { return Self.response(request, body: Self.memegenJSON) }
      return Self.response(request, body: Self.pngData, mimeType: "image/png")
    }
    var templateRequests: Int { log.urls.filter { $0.hasSuffix("/templates/") }.count }
    let dependencies = stubDependencies()
    let source = MemeTemplatesCatalog(
      definition: CatalogDefinition(
        identifier: "memes.templates", name: "Meme Templates", enabledByDefault: true,
        initialGlobalScope: .none, settings: []),
      dependencies: dependencies)

    // Empty cache: the launch scan touches nothing.
    await source.scan()
    XCTAssertTrue(source.objects.isEmpty)
    XCTAssertEqual(log.urls, [])
    XCTAssertFalse(dependencies.thumbnails.isPrefetching)

    // First browse fetches the template list (and starts the thumbnail prefetch).
    let children = await MemeTemplatesCatalogBase.loadBrowseChildren(dependencies)
    XCTAssertEqual(children.map(\.title), ["Drake Hotline Bling", "Futurama Fry"])
    XCTAssertEqual(log.urls.first, "https://api.memegen.link/templates/")
    XCTAssertEqual(templateRequests, 1)
    await dependencies.thumbnails.waitForPrefetch()

    // With the cache filled, the scan lists templates and still fetches nothing.
    await source.scan()
    XCTAssertEqual(source.objects.count, 2)
    XCTAssertEqual(templateRequests, 1)
    XCTAssertFalse(dependencies.thumbnails.isPrefetching)
  }

  func testBrowseShowsWhichProviderFailedAlongsidePartialResults() async throws {
    MockURLProtocol.requestHandler = { request in
      if request.url?.host() == "api.imgflip.com" { return Self.response(request, status: 503, body: "") }
      if request.url?.path() == "/templates/" { return Self.response(request, body: Self.memegenJSON) }
      throw URLError(.notConnectedToInternet)
    }
    let base = stubDependencies()
    let dependencies = MemeCatalogDependencies(
      library: base.library, thumbnails: base.thumbnails, favorites: base.favorites,
      providers: { [.memegen, .imgflip] })
    let children = await MemeTemplatesCatalogBase.loadBrowseChildren(dependencies)
    await dependencies.thumbnails.waitForPrefetch()
    XCTAssertEqual(children.first?.title, "Imgflip templates unavailable")
    XCTAssertEqual(children.count, 3)
  }

  func testPruneDeletesThumbnailsOfRemovedOrChangedTemplates() throws {
    let cache = MemeThumbnailCache(directory: temporaryDirectory, session: mockSession())
    let kept = Self.drake
    let removed = Self.template("gone", "Gone")
    let changed = MemeTemplate(
      provider: .memegen, id: "drake", name: kept.name, lineCount: 2,
      blankURL: URL(string: "https://api.memegen.link/images/drake-v2.png")!,
      exampleLines: [], keywords: [])
    XCTAssertNotEqual(cache.fileURL(for: kept), cache.fileURL(for: changed), "New image, new file")
    for template in [kept, removed, changed] {
      try Data([0xFF]).write(to: cache.fileURL(for: template))
    }

    cache.prune(keeping: [kept])
    let left = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
    XCTAssertEqual(left, [cache.fileURL(for: kept).lastPathComponent])
  }

  func testMissingCacheAndNetworkFailureIsReported() async {
    MockURLProtocol.requestHandler = { request in Self.response(request, status: 503, body: "") }
    let library = MemeTemplateLibrary(
      client: MemeAPIClient(session: mockSession()), directory: temporaryDirectory)
    let result = await library.load(providers: [.memegen])
    XCTAssertTrue(result.templates.isEmpty)
    XCTAssertEqual(result.failures[.memegen], MemeError.httpStatus(.memegen, 503).localizedDescription)
  }

  // MARK: Favorites

  func testFavoritesSortFirstAlphabeticallyAndPersist() throws {
    let defaults = InMemoryFavoritesStore()
    let favorites = MemeFavorites(defaults: defaults)
    let templates = [Self.template("a", "Alpha"), Self.template("b", "Bravo"), Self.template("c", "Charlie")]

    XCTAssertEqual(favorites.ordered(templates).map(\.id), ["a", "b", "c"])
    favorites.set(templates[2], favorite: true)
    favorites.set(templates[1], favorite: true)
    XCTAssertEqual(favorites.ordered(templates).map(\.id), ["b", "c", "a"])
    XCTAssertTrue(favorites.contains(templates[2]))

    favorites.set(templates[2], favorite: false)
    XCTAssertEqual(favorites.ordered(templates).map(\.id), ["b", "a", "c"])
    XCTAssertEqual(MemeFavorites(defaults: defaults).keys, ["memegen:b"])
  }

  // MARK: Make Meme

  @MainActor
  func testMakeMemeWritesImageAndRestagesIt() async throws {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://api.memegen.link/images/drake/Writing_Swift/Shipping_it.png")
      return Self.response(request, body: Self.pngData, mimeType: "image/png")
    }
    let result = await MemeMaker.make(
      template: Self.drake, text: "Writing Swift | Shipping it",
      client: MemeAPIClient(session: mockSession()), credentials: nil,
      directory: temporaryDirectory)

    guard case .subjects(let subjects) = result,
      let item = subjects.first as? MemeImageItem
    else { return XCTFail("Expected a meme subject, got \(result)") }

    XCTAssertEqual(item.typeID, .memeImage)
    XCTAssertEqual(item.title, "Writing Swift / Shipping it")
    XCTAssertEqual(item.url.pathExtension, "png")
    XCTAssertEqual(try Data(contentsOf: item.url), Self.pngData)
    XCTAssertEqual(item.pasteboardDataRepresentation?.typeRawValue, NSPasteboard.PasteboardType.png.rawValue)
    XCTAssertEqual(item.meme.remoteURL.host(), "api.memegen.link")
  }

  @MainActor
  func testMakeMemeWithoutTextUsesExampleAndRejectsNonImages() async {
    MockURLProtocol.requestHandler = { request in
      XCTAssertEqual(
        request.url?.absoluteString, "https://api.memegen.link/images/drake/Top/Bottom.png")
      return Self.response(request, body: Self.pngData, mimeType: "image/png")
    }
    let example = await MemeMaker.make(
      template: Self.drake, text: " | ", client: MemeAPIClient(session: mockSession()),
      credentials: nil, directory: temporaryDirectory)
    guard case .subjects(let subjects) = example else { return XCTFail("Expected a meme") }
    XCTAssertEqual(subjects.first?.title, "Top / Bottom")
    XCTAssertEqual(MemeText.exampleLines(for: Self.template("x", "No Example")), ["", ""])

    MockURLProtocol.requestHandler = { request in Self.response(request, body: "<html>") }
    let html = await MemeMaker.make(
      template: Self.drake, text: "a", client: MemeAPIClient(session: mockSession()),
      credentials: nil, directory: temporaryDirectory)
    guard case .failure(let htmlMessage) = html else { return XCTFail("Expected failure") }
    XCTAssertEqual(htmlMessage, MemeError.notAnImage.localizedDescription)
  }

  @MainActor
  func testMakeMemeRefusesAllBlankBoxesWithoutARequest() async {
    MockURLProtocol.requestHandler = { _ in
      XCTFail("No request for an all-blank meme")
      throw URLError(.badURL)
    }
    // Imgflip templates have no example text, so Enter on the untouched seed would be all blank.
    let result = await MemeMaker.make(
      template: Self.imgflipDrake, text: Self.imgflipDrake.textSeed,
      client: MemeAPIClient(session: mockSession()),
      credentials: ImgflipCredentials(username: "u", password: "p"), directory: temporaryDirectory)
    guard case .failure(let message) = result else { return XCTFail("Expected failure") }
    XCTAssertEqual(message, MemeError.emptyText.localizedDescription)
  }

  func testThumbnailsAreDownscaledCachedAndServedFromDisk() async throws {
    let png = try XCTUnwrap(Self.pngImage(width: 1200, height: 800))
    var requests = 0
    MockURLProtocol.requestHandler = { request in
      requests += 1
      return Self.response(request, body: png, mimeType: "image/png")
    }
    let cache = MemeThumbnailCache(directory: temporaryDirectory, session: mockSession())

    let first = await cache.image(for: Self.drake)
    XCTAssertNotNil(first)
    let stored = try XCTUnwrap(NSImage(contentsOf: cache.fileURL(for: Self.drake)))
    XCTAssertEqual(stored.representations.first?.pixelsWide, MemeThumbnailCache.maxPixelSize)
    XCTAssertEqual(
      cache.fileURL(for: Self.drake).lastPathComponent,
      "memegen_drake-\(MemeThumbnailCache.stableHash(Self.drake.thumbnailURL.absoluteString)).jpg")
    XCTAssertEqual(MemeThumbnailCache.stableHash("a"), "af63dc4c8601ec8c", "Stable across launches")

    MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
    let offline = await cache.image(for: Self.drake)
    XCTAssertNotNil(offline, "Served from disk while offline")
    XCTAssertEqual(requests, 1)
  }

  static func pngImage(width: Int, height: Int) -> Data? {
    let image = NSImage(size: NSSize(width: width, height: height))
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep else { return nil }
    image.addRepresentation(rep)
    return rep.representation(using: .png, properties: [:])
  }

  @MainActor
  func testFavoriteChangeRequestsExactlyOneRescanWithoutLooping() async {
    let catalog = MemeTemplatesBrowseCatalog(
      definition: CatalogDefinition(
        identifier: "memes.templates.browse", name: "Make Meme", enabledByDefault: true,
        settings: []))
    var rescans = 0
    let requested = expectation(description: "rescan requested")
    catalog.rescanHandler = {
      rescans += 1
      requested.fulfill()
    }

    NotificationCenter.default.post(name: .memeTemplatesDidChange, object: nil)
    await fulfillment(of: [requested], timeout: 2)

    // The rescan itself must not announce another change.
    await catalog.scan()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(rescans, 1)
    XCTAssertEqual(catalog.objects.count, 1)
    XCTAssertEqual(catalog.objects.first?.title, "Make Meme")
  }

  func testFavoritesTieBreakIsDeterministic() throws {
    let defaults = InMemoryFavoritesStore()
    let favorites = MemeFavorites(defaults: defaults)
    let a = Self.drake
    let b = Self.imgflipDrake
    favorites.set(a, favorite: true)
    favorites.set(b, favorite: true)
    XCTAssertEqual(favorites.ordered([a, b]).map(\.key), favorites.ordered([b, a]).map(\.key))
    XCTAssertEqual(favorites.ordered([b, a]).map(\.key), ["imgflip:181913649", "memegen:drake"])
  }

  func testFileStemIsSafe() {
    XCTAssertEqual(MemeFileStore.fileStem("Drake Hotline Bling"), "Drake-Hotline-Bling")
    XCTAssertEqual(MemeFileStore.fileStem("../../etc/passwd"), "etc-passwd")
    XCTAssertEqual(MemeFileStore.fileStem("???"), "meme")
  }

  // MARK: Fixtures

  static let drake = MemeTemplate(
    provider: .memegen, id: "drake", name: "Drake Hotline Bling", lineCount: 2,
    blankURL: URL(string: "https://api.memegen.link/images/drake.png")!,
    exampleLines: ["Top", "Bottom"], keywords: [])

  static let imgflipDrake = MemeTemplate(
    provider: .imgflip, id: "181913649", name: "Drake Hotline Bling", lineCount: 2,
    blankURL: URL(string: "https://i.imgflip.com/30b1gx.jpg")!, exampleLines: [], keywords: [])

  static func template(_ id: String, _ name: String) -> MemeTemplate {
    MemeTemplate(
      provider: .memegen, id: id, name: name, lineCount: 2,
      blankURL: URL(string: "https://api.memegen.link/images/\(id).png")!, exampleLines: [],
      keywords: [])
  }

  static let memegenJSON = """
    [
      {"id":"drake","name":"Drake Hotline Bling","lines":2,"overlays":0,"styles":[],
       "blank":"https://api.memegen.link/images/drake.png",
       "example":{"text":["Top","Bottom"],"url":"https://api.memegen.link/images/drake/Top/Bottom.png"},
       "source":"https://knowyourmeme.com","keywords":["hotline"]},
      {"id":"fry","name":"Futurama Fry","lines":2,"blank":"https://api.memegen.link/images/fry.png",
       "example":{"text":[],"url":"https://api.memegen.link/images/fry.png"}}
    ]
    """

  static let imgflipJSON = """
    {"success":true,"data":{"memes":[{"id":"181913649","name":"Drake Hotline Bling",
    "url":"https://i.imgflip.com/30b1gx.jpg","width":1200,"height":1200,"box_count":2,"captions":1}]}}
    """

  static let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

  static func response(
    _ request: URLRequest, status: Int = 200, body: String, mimeType: String = "application/json"
  ) -> (HTTPURLResponse, Data) {
    response(request, status: status, body: Data(body.utf8), mimeType: mimeType)
  }

  static func response(
    _ request: URLRequest, status: Int = 200, body: Data, mimeType: String
  ) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: ["Content-Type": mimeType])!
    return (response, body)
  }

  private func stubDependencies() -> MemeCatalogDependencies {
    let session = mockSession()
    return MemeCatalogDependencies(
      library: MemeTemplateLibrary(
        client: MemeAPIClient(session: session),
        directory: temporaryDirectory.appending(path: "templates", directoryHint: .isDirectory)),
      thumbnails: MemeThumbnailCache(
        directory: temporaryDirectory.appending(path: "thumbnails", directoryHint: .isDirectory),
        session: session),
      favorites: MemeFavorites(defaults: InMemoryFavoritesStore()),
      providers: { [.memegen] })
  }

  private func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

/// Favorites storage that never touches `~/Library/Preferences`.
private final class InMemoryFavoritesStore: MemeFavoritesStore {
  private var values: [String: Any] = [:]
  func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
  func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class RequestLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var urls: [String] { lock.withLock { stored } }
  func append(_ url: String) { lock.withLock { stored.append(url) } }
}

/// A tiny HTTP/1.1 server on 127.0.0.1 that records each raw request and answers via `respond`.
private final class LoopbackServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "MemeGeneratorTests.LoopbackServer")
  private let lock = NSLock()
  private var received: [String] = []
  private var handler: (String) -> Data = { _ in LoopbackServer.reply(status: 404) }
  private(set) var url: URL!

  var requests: [String] { lock.withLock { received } }
  var respond: (String) -> Data {
    get { lock.withLock { handler } }
    set { lock.withLock { handler = newValue } }
  }

  private init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
  }

  static func start() async throws -> LoopbackServer {
    let server = try LoopbackServer()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // Resume once: the handler removes itself on the first terminal state.
      server.listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          server.listener.stateUpdateHandler = nil
          server.url = URL(string: "http://127.0.0.1:\(server.listener.port!.rawValue)")!
          continuation.resume()
        case .failed(let error):
          server.listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default: break
        }
      }
      server.listener.newConnectionHandler = { server.serve($0) }
      server.listener.start(queue: server.queue)
    }
    return server
  }

  func stop() { listener.cancel() }

  static func reply(status: Int, headers: [String: String] = [:], body: String = "") -> Data {
    var head = "HTTP/1.1 \(status) Status\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    return Data((head + "\r\n" + body).utf8)
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, buffer: Data())
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = Self.completeRequest(buffer) {
        let response = lock.withLock { () -> (String) -> Data in
          received.append(request)
          return handler
        }(request)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
      } else if done || error != nil {
        connection.cancel()
      } else {
        receive(on: connection, buffer: buffer)
      }
    }
  }

  /// The whole request once the headers and `Content-Length` bytes of body have arrived.
  private static func completeRequest(_ data: Data) -> String? {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
    let length = head.split(separator: "\r\n")
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    guard data.count - end.upperBound >= length else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try XCTUnwrap(Self.requestHandler)
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
