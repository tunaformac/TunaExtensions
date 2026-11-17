import Foundation
import TunaKit

/// One configured upload destination, read from a Tuna extension connection record.
///
/// The connection's base URL is the S3 endpoint and its secret is the secret access key; every
/// other S3 setting lives in the record's declared fields.
struct CloudShareDestination: Sendable, Hashable {
  let id: String
  let name: String
  let endpoint: URL
  let region: String
  let bucket: String
  let accessKeyID: String
  let prefixTemplate: String
  let publicBaseURL: URL?
  let forcePathStyle: Bool
  let sendsPublicACL: Bool
  let filenameTemplate: String

  /// Reads the secret access key lazily so listing destinations never touches the Keychain.
  let secretProvider: @Sendable () -> String?

  static func == (lhs: CloudShareDestination, rhs: CloudShareDestination) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  /// S3 cannot serve a dotted bucket name over HTTPS as a virtual host (the wildcard certificate
  /// only covers one label), so those buckets always use path-style requests.
  var usesPathStyle: Bool {
    forcePathStyle || bucket.contains(".")
  }

  /// The complete folders of the prefix before its first placeholder; scopes bucket listings.
  /// `files/%year%/%month%` lists `files/`, and `%year%` lists the whole bucket.
  var listingPrefix: String {
    let literal = prefixTemplate.components(separatedBy: "%").first ?? ""
    var segments = literal.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if prefixTemplate.contains("%") {
      // The last segment runs into a placeholder, so it is incomplete.
      segments.removeLast()
    }
    let folders = segments.map(CloudShareFilename.sanitize).filter { !$0.isEmpty }
    return folders.isEmpty ? "" : folders.joined(separator: "/") + "/"
  }

  /// Every setting that changes what a bucket listing returns.
  var listingKey: String {
    [endpoint.absoluteString, region, bucket, accessKeyID, listingPrefix, String(usesPathStyle)]
      .joined(separator: "\n")
  }

  func requestURL(forKey key: String) -> URL {
    var components = URLComponents()
    components.scheme = endpoint.scheme ?? "https"
    components.port = endpoint.port
    let encodedKey = CloudShareSigner.encodePath(key)
    if usesPathStyle {
      components.host = endpoint.host
      components.percentEncodedPath = "/\(CloudShareSigner.encodePath(bucket))/\(encodedKey)"
    } else {
      components.host = "\(bucket).\(endpoint.host ?? "")"
      components.percentEncodedPath = "/\(encodedKey)"
    }
    return components.url!
  }

  /// The bucket-level URL used for ListObjectsV2.
  var bucketURL: URL {
    var components = URLComponents()
    components.scheme = endpoint.scheme ?? "https"
    components.port = endpoint.port
    if usesPathStyle {
      components.host = endpoint.host
      components.percentEncodedPath = "/\(CloudShareSigner.encodePath(bucket))/"
    } else {
      components.host = "\(bucket).\(endpoint.host ?? "")"
      components.percentEncodedPath = "/"
    }
    return components.url!
  }

  func publicURL(forKey key: String) -> URL {
    guard let publicBaseURL else { return requestURL(forKey: key) }
    let base = publicBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(base)/\(CloudShareSigner.encodePath(key))")!
  }
}

enum CloudShareDestinationError: LocalizedError, Equatable {
  case noDestinations
  case incomplete(name: String, missing: [String])
  case missingSecret(name: String)
  case invalidPublicURL(name: String)

  var errorDescription: String? {
    switch self {
    case .noDestinations:
      "Add a Cloud Share destination in Tuna Settings → Extensions → Cloud Share."
    case .incomplete(let name, let missing):
      "\(name) is missing \(missing.joined(separator: ", "))."
    case .missingSecret(let name):
      "\(name) has no secret access key. Edit the destination to add it."
    case .invalidPublicURL(let name):
      "\(name) has an invalid Public URL."
    }
  }
}

enum CloudShareSettings {
  static let providerIdentifier = "s3"

  static let accessKeyID = CatalogSettingDefinition(
    key: "AccessKeyID", type: .string, label: "Access Key ID", defaultValue: "",
    description: nil)
  static let region = CatalogSettingDefinition(
    key: "Region", type: .string, label: "Region", defaultValue: "us-east-1",
    description: "The bucket's AWS region, e.g. eu-central-1.")
  static let bucket = CatalogSettingDefinition(
    key: "Bucket", type: .string, label: "Bucket", defaultValue: "", description: nil)
  static let prefix = CatalogSettingDefinition(
    key: "Prefix", type: .string, label: "Path Prefix", defaultValue: "",
    description: "Optional folder for uploads. Supports %year%, %month%, and %day%.")
  static let publicURL = CatalogSettingDefinition(
    key: "PublicURL", type: .string, label: "Public URL", defaultValue: "",
    description:
      "Optional base for shared links, e.g. https://files.example.com. Leave empty to use the S3 URL."
  )
  static let filenameTemplate = CatalogSettingDefinition(
    key: "FilenameTemplate", type: .string, label: "Filename",
    defaultValue: CloudShareFilename.defaultTemplate,
    description:
      "Supports %filename%, %ext%, %random-N% (1–64), %uuid%, %date%, %year%, %month%, %day%, and %timestamp%. Names always end in the file's extension; a name without placeholders gets a random suffix."
  )
  static let publicACL = CatalogSettingDefinition(
    key: "PublicACL", type: .bool, label: "Upload with public-read ACL", defaultValue: "false",
    description:
      "Only for buckets with ACLs enabled. New AWS buckets disable ACLs; use a bucket policy instead."
  )
  static let pathStyle = CatalogSettingDefinition(
    key: "PathStyle", type: .bool, label: "Use path-style requests", defaultValue: "false",
    description: "Needed by some S3-compatible services. Buckets with dots always use it.")

  static let fields = [
    accessKeyID, region, bucket, prefix, publicURL, filenameTemplate, publicACL, pathStyle,
  ]

  static func store(for type: AnyClass) -> ExtensionConnectionStore? {
    guard let bundleIdentifier = Bundle(for: type).bundleIdentifier else { return nil }
    return ExtensionConnectionStore(
      extensionIdentifier: bundleIdentifier,
      providerIdentifier: providerIdentifier
    )
  }

  /// Cheap: decodes the records blob only, no Keychain access.
  static func destinationCount(for type: AnyClass) -> Int {
    store(for: type)?.records().count ?? 0
  }

  static func destinations(for type: AnyClass) -> [Result<CloudShareDestination, Error>] {
    guard let store = store(for: type) else { return [] }
    return store.orderedRecords().map { record in
      Result { try destination(from: record, store: store) }
    }
  }

  static func defaultDestination(for type: AnyClass) throws -> CloudShareDestination {
    guard let store = store(for: type), let record = store.defaultRecord() else {
      throw CloudShareDestinationError.noDestinations
    }
    return try destination(from: record, store: store)
  }

  static func destination(
    from record: ExtensionConnectionRecord,
    store: ExtensionConnectionStore
  ) throws -> CloudShareDestination {
    try destination(from: record) {
      store.accessToken(for: record)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  static func destination(
    from record: ExtensionConnectionRecord,
    secretProvider: @escaping @Sendable () -> String?
  ) throws -> CloudShareDestination {
    func value(_ field: CatalogSettingDefinition) -> String {
      record.fieldValue(for: field).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let name = record.trimmedDisplayName.isEmpty ? "Destination" : record.trimmedDisplayName
    let regionValue = value(region)
    var missing: [String] = []
    if value(accessKeyID).isEmpty { missing.append("an Access Key ID") }
    if value(bucket).isEmpty { missing.append("a Bucket") }
    if regionValue.isEmpty { missing.append("a Region") }
    guard missing.isEmpty else {
      throw CloudShareDestinationError.incomplete(name: name, missing: missing)
    }

    let endpointString = record.trimmedBaseURLString.isEmpty
      ? "https://s3.\(regionValue).amazonaws.com"
      : record.trimmedBaseURLString
    guard let endpoint = URL(string: endpointString), endpoint.host != nil else {
      throw CloudShareDestinationError.incomplete(name: name, missing: ["a valid Endpoint"])
    }

    var publicBaseURL: URL?
    let publicValue = value(publicURL)
    if !publicValue.isEmpty {
      let candidate = publicValue.contains("://") ? publicValue : "https://\(publicValue)"
      guard let url = URL(string: candidate), url.host != nil else {
        throw CloudShareDestinationError.invalidPublicURL(name: name)
      }
      publicBaseURL = url
    }

    let template = value(filenameTemplate)
    return CloudShareDestination(
      id: record.id,
      name: name,
      endpoint: endpoint,
      region: regionValue,
      bucket: value(bucket),
      accessKeyID: value(accessKeyID),
      prefixTemplate: value(prefix),
      publicBaseURL: publicBaseURL,
      forcePathStyle: record.boolFieldValue(for: pathStyle),
      sendsPublicACL: record.boolFieldValue(for: publicACL),
      filenameTemplate: template.isEmpty ? CloudShareFilename.defaultTemplate : template,
      secretProvider: secretProvider
    )
  }
}

/// Expands filename and prefix templates into an object key.
enum CloudShareFilename {
  static let defaultTemplate = "%filename%-%random-6%"

  private static let randomAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

  static func key<R: RandomNumberGenerator>(
    for originalFilename: String,
    destination: CloudShareDestination,
    date: Date = Date(),
    generator: inout R
  ) -> String {
    let name = filename(
      for: originalFilename, template: destination.filenameTemplate, date: date,
      generator: &generator)
    let prefix = expandDates(in: destination.prefixTemplate, date: date)
      .split(separator: "/", omittingEmptySubsequences: true)
      .map { sanitize(String($0)) }
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    return prefix.isEmpty ? name : "\(prefix)/\(name)"
  }

  static func key(for originalFilename: String, destination: CloudShareDestination) -> String {
    var generator = SystemRandomNumberGenerator()
    return key(for: originalFilename, destination: destination, generator: &generator)
  }

  static func filename<R: RandomNumberGenerator>(
    for originalFilename: String,
    template: String,
    date: Date,
    generator: inout R
  ) -> String {
    let (base, pathExtension) = splitExtension(originalFilename)

    var effectiveTemplate = template
    // As in Dropshare, a fixed name would overwrite the previous upload every time.
    if !effectiveTemplate.contains("%") {
      effectiveTemplate += "-%random-6%"
    }

    var result = effectiveTemplate
      .replacingOccurrences(of: "%filename%", with: base)
      .replacingOccurrences(of: "%ext%", with: pathExtension)
      .replacingOccurrences(of: "%timestamp%", with: String(Int(date.timeIntervalSince1970)))
      .replacingOccurrences(of: "%date%", with: dateString(date, format: "yyyy-MM-dd"))
    result = expandDates(in: result, date: date)
    while let range = result.range(of: "%uuid%") {
      result.replaceSubrange(range, with: UUID().uuidString.lowercased())
    }
    result = expandRandom(in: result, generator: &generator)
    result = sanitize(result)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

    if result.isEmpty {
      result = randomString(length: 8, generator: &generator)
    }
    // The extension always ends the name, once: `%filename%.%ext%` already ends with it.
    if pathExtension.isEmpty || result.lowercased().hasSuffix(".\(pathExtension)") { return result }
    return "\(result).\(pathExtension)"
  }

  /// The sanitized base name and lowercased extension. `.tar.gz` and friends count as one
  /// extension so a suffix lands before them, not between.
  static func splitExtension(_ filename: String) -> (base: String, ext: String) {
    var base = (filename as NSString).deletingPathExtension
    var ext = (filename as NSString).pathExtension
    if !ext.isEmpty, (base as NSString).pathExtension.lowercased() == "tar" {
      ext = "tar.\(ext)"
      base = (base as NSString).deletingPathExtension
    }
    return (sanitize(base), sanitize(ext).lowercased())
  }

  /// Keeps names URL-friendly: folds diacritics, turns whitespace into dashes, and drops
  /// anything outside ASCII letters, digits, `-`, `_`, and `.`. Placeholders are expanded first.
  static func sanitize(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    var output = ""
    var lastWasDash = false
    for scalar in folded.unicodeScalars {
      if scalar.isASCII,
        CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
      {
        output.unicodeScalars.append(scalar)
        lastWasDash = scalar == "-"
      } else if CharacterSet.whitespaces.contains(scalar) || scalar == "/" {
        if !lastWasDash, !output.isEmpty {
          output.append("-")
          lastWasDash = true
        }
      }
    }
    return output
  }

  private static func expandDates(in value: String, date: Date) -> String {
    value
      .replacingOccurrences(of: "%year%", with: dateString(date, format: "yyyy"))
      .replacingOccurrences(of: "%month%", with: dateString(date, format: "MM"))
      .replacingOccurrences(of: "%day%", with: dateString(date, format: "dd"))
  }

  private static func expandRandom<R: RandomNumberGenerator>(
    in value: String, generator: inout R
  ) -> String {
    var result = value
    while let start = result.range(of: "%random-") {
      guard let end = result[start.upperBound...].firstIndex(of: "%"),
        let length = Int(result[start.upperBound..<end]), (1...64).contains(length)
      else {
        // Leave malformed placeholders for sanitize to strip.
        result.replaceSubrange(start, with: "random-")
        continue
      }
      result.replaceSubrange(
        start.lowerBound...end, with: randomString(length: length, generator: &generator))
    }
    return result
  }

  static func randomString<R: RandomNumberGenerator>(length: Int, generator: inout R) -> String {
    String((0..<length).map { _ in randomAlphabet.randomElement(using: &generator)! })
  }

  private static func dateString(_ date: Date, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
}
