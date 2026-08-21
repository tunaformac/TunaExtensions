import Foundation

struct FancyTextFont: Decodable, Sendable {
  let name: String
  private let lowercase: CharacterMap
  private let uppercase: CharacterMap
  private let digits: CharacterMap
  private let experimental: Bool

  private enum CodingKeys: String, CodingKey {
    case name = "fontName"
    case lowercase = "fontLower"
    case uppercase = "fontUpper"
    case digits = "fontDigits"
    case experimental = "experimentalFont"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    lowercase = try container.decodeIfPresent(CharacterMap.self, forKey: .lowercase) ?? .text("")
    uppercase = try container.decodeIfPresent(CharacterMap.self, forKey: .uppercase) ?? .text("")
    digits = try container.decodeIfPresent(CharacterMap.self, forKey: .digits) ?? .text("")
    experimental = try container.decodeIfPresent(Bool.self, forKey: .experimental) ?? false
  }

  func convert(_ text: String) -> String {
    let lowercase = lowercase.values(or: Self.referenceLowercase)
    let uppercase = uppercase.values(or: Self.referenceUppercase)
    let digits = digits.values(or: Self.referenceDigits)

    return text.map { character in
      if let index = Self.referenceLowercase.firstIndex(of: character) {
        return lowercase[safe: index] ?? ""
      }
      if let index = Self.referenceUppercase.firstIndex(of: character) {
        return uppercase[safe: index] ?? ""
      }
      if let index = Self.referenceDigits.firstIndex(of: character) {
        return digits[safe: index] ?? ""
      }
      return String(character)
    }.joined()
  }

  static var productionFonts: [FancyTextFont] {
    get throws {
      try allFonts.filter { !$0.experimental }
    }
  }

  private static var allFonts: [FancyTextFont] {
    get throws {
      guard let url = Bundle(for: FancyTextExtension.self).url(forResource: "fonts", withExtension: "json") else {
        throw CocoaError(.fileNoSuchFile)
      }
      return try JSONDecoder().decode([FancyTextFont].self, from: Data(contentsOf: url))
    }
  }

  private static let referenceLowercase = Array("abcdefghijklmnopqrstuvwxyz")
  private static let referenceUppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
  private static let referenceDigits = Array("0123456789")
}

private enum CharacterMap: Decodable, Sendable {
  case text(String)
  case characters([String])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      self = .characters(try container.decode([String].self))
    }
  }

  func values(or fallback: [Character]) -> [String] {
    let values: [String]
    switch self {
    case .text(let text):
      values = text.map(String.init)
    case .characters(let characters):
      values = characters
    }
    return values.isEmpty ? fallback.map(String.init) : values
  }
}

private extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
