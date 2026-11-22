import Foundation

struct GeneratedMeme: Sendable {
  let template: MemeTemplate
  let lines: [String]
  let remoteURL: URL
  let imageData: Data
  let fileExtension: String
}

enum MemeURLSessions {
  static let direct: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    return URLSession(configuration: configuration)
  }()
}

/// Refuses every redirect, so credential-bearing requests only reach the URL they were built for.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  static let shared = NoRedirectDelegate()

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

struct MemeAPIClient: Sendable {
  static let live = MemeAPIClient()

  private let session: URLSession
  private let memegenBaseURL: URL
  private let imgflipBaseURL: URL

  init(
    session: URLSession = MemeURLSessions.direct,
    memegenBaseURL: URL = MemegenURLBuilder.base,
    imgflipBaseURL: URL = URL(string: "https://api.imgflip.com")!
  ) {
    self.session = session
    self.memegenBaseURL = memegenBaseURL
    self.imgflipBaseURL = imgflipBaseURL
  }

  // MARK: Templates

  func templates(from provider: MemeProvider) async throws -> [MemeTemplate] {
    switch provider {
    case .memegen: try await memegenTemplates()
    case .imgflip: try await imgflipTemplates()
    }
  }

  func memegenTemplates() async throws -> [MemeTemplate] {
    let data = try await get(memegenBaseURL.appending(path: "templates/"), provider: .memegen)
    do {
      return try JSONDecoder().decode([MemegenTemplateDTO].self, from: data).map(\.template)
    } catch {
      throw MemeError.invalidResponse(.memegen)
    }
  }

  func imgflipTemplates() async throws -> [MemeTemplate] {
    let data = try await get(imgflipBaseURL.appending(path: "get_memes"), provider: .imgflip)
    guard let response = try? JSONDecoder().decode(ImgflipGetMemesResponse.self, from: data) else {
      throw MemeError.invalidResponse(.imgflip)
    }
    guard response.success, let memes = response.data?.memes else {
      throw MemeError.provider(.imgflip, response.errorMessage ?? "Could not load templates.")
    }
    return memes.map {
      MemeTemplate(
        provider: .imgflip, id: $0.id, name: $0.name, lineCount: max($0.boxCount, 1),
        blankURL: $0.url, exampleLines: [], keywords: [])
    }
  }

  // MARK: Generation

  func generate(
    template: MemeTemplate,
    lines: [String],
    imgflipCredentials: ImgflipCredentials?
  ) async throws -> GeneratedMeme {
    let remoteURL: URL
    switch template.provider {
    case .memegen:
      remoteURL = MemegenURLBuilder.imageURL(templateID: template.id, lines: lines)
    case .imgflip:
      guard let imgflipCredentials else { throw MemeError.missingImgflipCredentials }
      remoteURL = try await imgflipCaption(
        templateID: template.id, lines: lines, credentials: imgflipCredentials)
    }
    let (data, fileExtension) = try await image(at: remoteURL, provider: template.provider)
    return GeneratedMeme(
      template: template, lines: lines, remoteURL: remoteURL, imageData: data,
      fileExtension: fileExtension)
  }

  func imgflipCaptionRequest(
    templateID: String, lines: [String], credentials: ImgflipCredentials
  ) -> URLRequest {
    var request = URLRequest(url: imgflipBaseURL.appending(path: "caption_image"))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var items = [
      URLQueryItem(name: "template_id", value: templateID),
      URLQueryItem(name: "username", value: credentials.username),
      URLQueryItem(name: "password", value: credentials.password),
    ]
    for (index, line) in lines.enumerated() {
      items.append(URLQueryItem(name: "boxes[\(index)][text]", value: line))
    }
    request.httpBody = Data(Self.formEncode(items).utf8)
    return request
  }

  private func imgflipCaption(
    templateID: String, lines: [String], credentials: ImgflipCredentials
  ) async throws -> URL {
    let request = imgflipCaptionRequest(
      templateID: templateID, lines: lines, credentials: credentials)
    // The body carries the Imgflip password: never let a redirect (307/308 replay the body) send it
    // anywhere else.
    let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate.shared)
    try Self.check(response, provider: .imgflip)
    guard let decoded = try? JSONDecoder().decode(ImgflipCaptionResponse.self, from: data) else {
      throw MemeError.invalidResponse(.imgflip)
    }
    guard decoded.success, let url = decoded.data?.url else {
      throw MemeError.provider(.imgflip, decoded.errorMessage ?? "Could not create the meme.")
    }
    return url
  }

  private func image(at url: URL, provider: MemeProvider) async throws -> (Data, String) {
    var request = URLRequest(url: url)
    request.setValue("image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    try Self.check(response, provider: provider)
    guard let fileExtension = Self.imageExtension(of: data) else { throw MemeError.notAnImage }
    return (data, fileExtension)
  }

  private func get(_ url: URL, provider: MemeProvider) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    try Self.check(response, provider: provider)
    return data
  }

  private static func check(_ response: URLResponse, provider: MemeProvider) throws {
    guard let http = response as? HTTPURLResponse else { throw MemeError.invalidResponse(provider) }
    guard (200..<300).contains(http.statusCode) else {
      throw MemeError.httpStatus(provider, http.statusCode)
    }
  }

  static func imageExtension(of data: Data) -> String? {
    let bytes = [UInt8](data.prefix(8))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
    if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
    if bytes.count >= 4, bytes[0...3] == [0x52, 0x49, 0x46, 0x46] { return "webp" }
    return nil
  }

  static func formEncode(_ items: [URLQueryItem]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return items.map { item in
      let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
      let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return "\(name)=\(value)"
    }.joined(separator: "&")
  }
}
