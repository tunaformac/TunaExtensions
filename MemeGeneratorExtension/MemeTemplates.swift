import Foundation

enum MemeProvider: String, Codable, Sendable, CaseIterable {
  case memegen
  case imgflip

  var displayName: String {
    switch self {
    case .memegen: "Memegen"
    case .imgflip: "Imgflip"
    }
  }
}

struct MemeTemplate: Codable, Hashable, Sendable {
  let provider: MemeProvider
  let id: String
  let name: String
  let lineCount: Int
  let blankURL: URL
  let exampleLines: [String]
  let keywords: [String]

  /// Stable across providers; used for favorites and catalog item IDs.
  var key: String { "\(provider.rawValue):\(id)" }

  /// Smaller image for grid thumbnails. Memegen resizes server-side; Imgflip has no resize API.
  var thumbnailURL: URL {
    guard provider == .memegen,
      var components = URLComponents(url: blankURL, resolvingAgainstBaseURL: false)
    else { return blankURL }
    components.queryItems = [URLQueryItem(name: "width", value: "300")]
    return components.url ?? blankURL
  }

  /// Seed shown in the text pane: one numbered placeholder per box, e.g. `[Text 1] | [Text 2]`.
  /// Numbers work for every layout (top/bottom, left/right, three-panel, …).
  var textSeed: String {
    MemeText.placeholders(lineCount: lineCount).joined(separator: " | ")
  }
}

// MARK: - Text

enum MemeText {
  /// Splits `top | bottom` input into exactly `lineCount` lines.
  /// Newlines also separate lines. Extra segments are folded into the last line so no text is lost;
  /// missing segments become blank lines.
  static func lines(from input: String, lineCount: Int) -> [String] {
    let count = max(lineCount, 1)
    var segments = input
      .replacingOccurrences(of: "\r\n", with: "\n")
      .split(omittingEmptySubsequences: false) { $0 == "|" || $0 == "\n" }
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if segments.count > count {
      let tail = segments[(count - 1)...].joined(separator: " | ")
      segments = Array(segments[..<(count - 1)]) + [tail]
    }
    while segments.count < count { segments.append("") }
    return segments
  }

  /// Lines used when Make Meme runs without typed text: the template's example, or blank boxes.
  static func exampleLines(for template: MemeTemplate) -> [String] {
    let count = max(template.lineCount, 1)
    let example = Array(template.exampleLines.prefix(count))
    return example + Array(repeating: "", count: count - example.count)
  }

  static func placeholders(lineCount: Int) -> [String] {
    (1...max(lineCount, 1)).map { "[Text \($0)]" }
  }

  /// Matches `[Text 2]` (and looser forms like `[insert text 2]`) left untouched in the text pane.
  static func isPlaceholder(_ line: String) -> Bool {
    line.range(
      of: #"^\[(insert )?([a-z]+ )?text( \d+)?\]$"#, options: [.regularExpression, .caseInsensitive])
      != nil
  }

  /// Final box text. Untouched `[Text n]` placeholders fall back to that box's example text
  /// (or stay blank), so pressing Enter on the seed still makes a sensible meme.
  static func resolvedLines(from input: String, template: MemeTemplate) -> [String] {
    let example = exampleLines(for: template)
    guard hasText(input) else { return example }
    return lines(from: input, lineCount: template.lineCount).enumerated().map { index, line in
      isPlaceholder(line) ? example[index] : line
    }
  }

  static func hasText(_ input: String) -> Bool {
    input.contains { !$0.isWhitespace && $0 != "|" }
  }
}

// MARK: - Memegen

enum MemegenURLBuilder {
  static let base = URL(string: "https://api.memegen.link")!

  /// Memegen's documented special-character escapes for path segments.
  static func escape(_ text: String) -> String {
    var result = ""
    for character in text {
      switch character {
      case "_": result += "__"
      case "-": result += "--"
      case " ": result += "_"
      case "\n": result += "~n"
      case "?": result += "~q"
      case "&": result += "~a"
      case "%": result += "~p"
      case "#": result += "~h"
      case "/": result += "~s"
      case "\\": result += "~b"
      case "<": result += "~l"
      case ">": result += "~g"
      case "\"": result += "''"
      default: result.append(character)
      }
    }
    return result
  }

  static func imageURL(templateID: String, lines: [String]) -> URL {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#;")
    let segments = [templateID] + lines.map { line in
      line.isEmpty ? "_" : escape(line)
    }
    let path = segments
      .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
      .joined(separator: "/")
    return URL(string: "\(base.absoluteString)/images/\(path).png")!
  }
}

struct MemegenTemplateDTO: Decodable {
  struct Example: Decodable {
    let text: [String]?
  }

  let id: String
  let name: String
  let lines: Int
  let blank: URL
  let example: Example?
  let keywords: [String]?

  var template: MemeTemplate {
    MemeTemplate(
      provider: .memegen,
      id: id,
      name: name,
      lineCount: max(lines, 1),
      blankURL: blank,
      exampleLines: example?.text ?? [],
      keywords: keywords ?? []
    )
  }
}

// MARK: - Imgflip

struct ImgflipGetMemesResponse: Decodable {
  struct Payload: Decodable {
    let memes: [Meme]
  }

  struct Meme: Decodable {
    let id: String
    let name: String
    let url: URL
    let boxCount: Int

    enum CodingKeys: String, CodingKey {
      case id, name, url
      case boxCount = "box_count"
    }
  }

  let success: Bool
  let data: Payload?
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case success, data
    case errorMessage = "error_message"
  }
}

struct ImgflipCaptionResponse: Decodable {
  struct Payload: Decodable {
    let url: URL
  }

  let success: Bool
  let data: Payload?
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case success, data
    case errorMessage = "error_message"
  }
}

struct ImgflipCredentials: Equatable, Sendable {
  let username: String
  let password: String
}

// MARK: - Errors

enum MemeError: LocalizedError, Equatable {
  case invalidResponse(MemeProvider)
  case httpStatus(MemeProvider, Int)
  case provider(MemeProvider, String)
  case missingImgflipCredentials
  case notAnImage
  case emptyText

  var errorDescription: String? {
    switch self {
    case .invalidResponse(let provider):
      "\(provider.displayName) returned an invalid response."
    case .httpStatus(let provider, let status):
      "\(provider.displayName) returned HTTP \(status)."
    case .provider(let provider, let message):
      "\(provider.displayName): \(message)"
    case .missingImgflipCredentials:
      "Add your Imgflip username and password in the Meme Generator settings."
    case .notAnImage:
      "The meme service did not return an image."
    case .emptyText:
      "This template has no example text. Type the meme text, separating boxes with |"
    }
  }
}
