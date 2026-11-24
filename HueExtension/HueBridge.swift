import Foundation
import Security

enum HueGroupKind: String, Sendable {
  case room, zone

  var label: String { self == .room ? "Hue Room" : "Hue Zone" }
}

struct HueGroup: Sendable {
  let id: UUID
  let name: String
  let kind: HueGroupKind
  let lightID: UUID
  var isOn: Bool?
  let isOffline: Bool?
}

enum HueError: LocalizedError {
  case configuration(String)
  case authorization
  case http(Int)
  case response
  case rejected
  case disconnected
  case pairingTimedOut

  var errorDescription: String? {
    switch self {
    case .configuration(let message): return message
    case .authorization: return "Hue rejected the application key. Use Manage Hue Bridges to check the connection."
    case .http(let status): return "The Hue bridge returned HTTP \(status)."
    case .response: return "The Hue bridge returned an unexpected response."
    case .rejected: return "The Hue bridge reported an error for this request."
    case .disconnected: return "This Hue bridge is disconnected. Rescan Hue Groups and choose a connected group."
    case .pairingTimedOut: return "The bridge didn’t detect a button press in time."
    }
  }
}

struct HueBridge: Sendable {
  let id: String
  private let baseURL: URL
  private let key: String?
  private let trust: HueTrust

  init(address: String, id: String, key: String? = nil, caPEM: String) throws {
    guard id.utf8.count == 16, id.utf8.allSatisfy({
      (48...57).contains($0) || (97...102).contains($0)
    }) else {
      throw HueError.configuration("Enter the 16-digit hexadecimal Hue bridge ID.")
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = address
    let allowedHost = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard !address.isEmpty, address.unicodeScalars.allSatisfy(allowedHost.contains),
          let baseURL = components.url else {
      throw HueError.configuration("Enter the bridge IPv4 address or local hostname.")
    }
    if let key, key.isEmpty || !key.utf8.allSatisfy({ (33...126).contains($0) }) {
      throw HueError.configuration("Enter the Hue application key.")
    }

    self.id = id
    self.baseURL = baseURL
    self.key = key
    self.trust = try HueTrust(bridgeID: id, caPEM: caPEM)
  }

  func groups() async throws -> [HueGroup] {
    async let rooms: [GroupResource] = request(HueGroupKind.room.rawValue)
    async let zones: [GroupResource] = request(HueGroupKind.zone.rawValue)
    async let groupedLights: [GroupedLight]? = try? request("grouped_light")
    async let lights: [LightResource]? = try? request("light")
    async let connectivity: [ZigbeeConnectivity]? = try? request("zigbee_connectivity")
    let (roomResources, zoneResources) = try await (rooms, zones)
    var power: [UUID: Bool] = [:]
    for light in await groupedLights ?? [] {
      power[light.id] = light.on?.on
    }
    let reachability = await LightReachability(lights: lights ?? [], connectivity: connectivity ?? [])
    return groups(from: roomResources, kind: .room, power: power, reachability: reachability)
      + groups(from: zoneResources, kind: .zone, power: power, reachability: reachability)
  }

  func name() async throws -> String? {
    struct Configuration: Decodable { let name: String? }

    let url = baseURL.appendingPathComponent("api/config")
    let data = try await send(URLRequest(url: url, timeoutInterval: 2))
    return try JSONDecoder().decode(Configuration.self, from: data).name?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func pair() async throws -> String {
    var request = URLRequest(url: baseURL.appendingPathComponent("api"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"devicetype":"tuna-hue#mac"}"#.utf8)

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(90)
    while clock.now < deadline {
      try Task.checkCancellation()
      let data = try await send(request)
      let replies = try JSONDecoder().decode([PairingReply].self, from: data)
      if let username = replies.first?.success?.username, !username.isEmpty { return username }
      guard replies.first?.error?.type == 101 else { throw HueError.rejected }
      try await Task.sleep(for: .seconds(1))
    }
    throw HueError.pairingTimedOut
  }

  func setPower(_ on: Bool, lightID: UUID) async throws {
    let result: [Service] = try await request(
      "grouped_light/\(lightID.uuidString.lowercased())",
      body: JSONEncoder().encode(Power(on: .init(on: on)))
    )
    guard result.contains(where: { $0.rid == lightID && $0.rtype == "grouped_light" }) else {
      throw HueError.response
    }
  }

  private func groups(
    from resources: [GroupResource], kind: HueGroupKind, power: [UUID: Bool],
    reachability: LightReachability
  ) -> [HueGroup] {
    resources.compactMap { resource in
      guard let service = resource.services.first(where: { $0.rtype == "grouped_light" }) else {
        return nil
      }
      return HueGroup(
        id: resource.id, name: resource.metadata.name, kind: kind, lightID: service.rid,
        isOn: power[service.rid], isOffline: reachability.isOffline(resource.children ?? [])
      )
    }
  }

  private func request<Value: Decodable>(_ path: String, body: Data? = nil) async throws -> [Value] {
    guard let key else { throw HueError.configuration("Enter the Hue application key.") }
    let url = baseURL.appendingPathComponent("clip/v2/resource/\(path)")
    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "hue-application-key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpMethod = "PUT"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let data = try await send(request)
    let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
    guard envelope.errors.isEmpty else { throw HueError.rejected }
    return envelope.data
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 10
    config.tlsMinimumSupportedProtocolVersion = .TLSv12
    let session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw HueError.response }
    if http.statusCode == 401 || http.statusCode == 403 { throw HueError.authorization }
    guard (200..<300).contains(http.statusCode) else { throw HueError.http(http.statusCode) }

    return data
  }
}

private struct PairingReply: Decodable {
  struct Success: Decodable { let username: String }
  struct Failure: Decodable { let type: Int }
  let success: Success?
  let error: Failure?
}

struct DiscoveredHueBridge: Decodable, Hashable {
  let id: String
  let internalipaddress: String

  static let caPath = ProcessInfo.processInfo.environment["TUNA_HUE_DISCOVERY_CA_PEM"] ?? ""

  private static func certificates() throws -> String {
    if caPath.isEmpty { return hueRootCertificates }
    return try String(contentsOfFile: (caPath as NSString).expandingTildeInPath, encoding: .utf8)
  }

  func pairingClient() throws -> HueBridge {
    try HueBridge(address: internalipaddress, id: id.lowercased(), caPEM: Self.certificates())
  }

  func displayName() async -> String {
    if let client = try? pairingClient(),
       let name = try? await client.name(), !name.isEmpty {
      return name
    }
    return "Hue Bridge \(id.uppercased())"
  }

  static func discover() async throws -> [Self] {
    let endpoint = ProcessInfo.processInfo.environment["TUNA_HUE_DISCOVERY_URL"]
    guard let url = URL(string: endpoint ?? "https://discovery.meethue.com"),
          url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
          url.user == nil, url.password == nil else {
      throw HueError.configuration("Set the Hue discovery endpoint to an HTTPS URL.")
    }
    guard endpoint != nil || caPath.isEmpty else {
      throw HueError.configuration("Set a custom discovery endpoint when supplying a discovery CA.")
    }
    let session: URLSession
    if endpoint != nil {
      let trust = caPath.isEmpty ? nil : try HueTrust(bridgeID: nil, caPEM: certificates())
      session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
    } else {
      session = .shared
    }
    defer { if endpoint != nil { session.finishTasksAndInvalidate() } }
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HueError.response }
    return Array(Set(try JSONDecoder().decode([Self].self, from: data))).sorted { $0.id < $1.id }
  }
}

private struct GroupResource: Decodable {
  struct Metadata: Decodable { let name: String }
  let id: UUID
  let metadata: Metadata
  let services: [Service]
  let children: [Service]?
}

private struct LightResource: Decodable {
  let id: UUID
  let owner: Service
}

private struct ZigbeeConnectivity: Decodable {
  let owner: Service
  let status: String
}

private struct LightReachability {
  private let ownersByLight: [UUID: UUID]
  private let lightOwners: Set<UUID>
  private let offlineByDevice: [UUID: Bool]

  init(lights: [LightResource], connectivity: [ZigbeeConnectivity]) {
    ownersByLight = Dictionary(lights.map { ($0.id, $0.owner.rid) }, uniquingKeysWith: { first, _ in first })
    lightOwners = Set(ownersByLight.values)
    var offline: [UUID: Bool] = [:]
    for link in connectivity {
      switch link.status {
      case "disconnected", "connectivity_issue": offline[link.owner.rid] = true
      case "connected": offline[link.owner.rid] = false
      default: break
      }
    }
    offlineByDevice = offline
  }

  func isOffline(_ children: [Service]) -> Bool? {
    // Rooms reference devices, including accessories. Zones reference lights directly.
    let lights = children.filter { child in
      child.rtype == "light" || (child.rtype == "device" && lightOwners.contains(child.rid))
    }
    let states = lights.map { light in
      let owner = light.rtype == "device" ? light.rid : ownersByLight[light.rid]
      return owner.flatMap { offlineByDevice[$0] }
    }
    if states.contains(false) { return false }
    return !states.isEmpty && states.allSatisfy { $0 == true } ? true : nil
  }
}

private struct GroupedLight: Decodable {
  struct Power: Decodable { let on: Bool? }
  let id: UUID
  let on: Power?
}

private struct Service: Decodable {
  let rid: UUID
  let rtype: String
}

private struct Envelope<Value: Decodable>: Decodable {
  struct APIError: Decodable {}
  let data: [Value]
  let errors: [APIError]
}

private struct Power: Encodable {
  struct State: Encodable { let on: Bool }
  let on: State
}

private final class HueTrust: NSObject, URLSessionTaskDelegate, Sendable {
  private let bridgeID: String?
  private let anchors: [SecCertificate]

  init(bridgeID: String?, caPEM: String) throws {
    self.bridgeID = bridgeID
    let pattern = /-----BEGIN CERTIFICATE-----([A-Za-z0-9+\/=\s]+)-----END CERTIFICATE-----/
    anchors = caPEM.matches(of: pattern).compactMap { match in
      let base64 = match.output.1.filter { !$0.isWhitespace }
      guard let der = Data(base64Encoded: base64) else { return nil }
      return SecCertificateCreateWithData(nil, der as CFData)
    }
    guard !anchors.isEmpty else {
      throw HueError.configuration("Choose the official Philips Hue root CA PEM file.")
    }
  }

  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Hue bridge certificates can outlive the SSL policy limit. Check the chain against
    // the dedicated Hue roots and match the bridge ID in the leaf instead.
    let policy = bridgeID == nil
      ? SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)
      : SecPolicyCreateBasicX509()
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust,
          SecTrustSetPolicies(trust, policy) == errSecSuccess,
          SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
          SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
          SecTrustEvaluateWithError(trust, nil),
          bridgeID.map({ id in
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
            return matchesBridgeID(leaf, id: id)
          }) ?? true else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  private func matchesBridgeID(_ certificate: SecCertificate, id: String) -> Bool {
    // Hue bridge certificates can carry the bridge ID only in the subject common name.
    var commonName: CFString?
    return SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess
      && (commonName as String?)?.lowercased() == id
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

// Philips Hue bridge roots from the Hue HTTPS guide, mirrored by OpenHue.
let hueRootCertificates = """
-----BEGIN CERTIFICATE-----
MIICMjCCAdigAwIBAgIUO7FSLbaxikuXAljzVaurLXWmFw4wCgYIKoZIzj0EAwIw
OTELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRQwEgYDVQQDDAty
b290LWJyaWRnZTAiGA8yMDE3MDEwMTAwMDAwMFoYDzIwMzgwMTE5MDMxNDA3WjA5
MQswCQYDVQQGEwJOTDEUMBIGA1UECgwLUGhpbGlwcyBIdWUxFDASBgNVBAMMC3Jv
b3QtYnJpZGdlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjNw2tx2AplOf9x86
aTdvEcL1FU65QDxziKvBpW9XXSIcibAeQiKxegpq8Exbr9v6LBnYbna2VcaK0G22
jOKkTqOBuTCBtjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNV
HQ4EFgQUZ2ONTFrDT6o8ItRnKfqWKnHFGmQwdAYDVR0jBG0wa4AUZ2ONTFrDT6o8
ItRnKfqWKnHFGmShPaQ7MDkxCzAJBgNVBAYTAk5MMRQwEgYDVQQKDAtQaGlsaXBz
IEh1ZTEUMBIGA1UEAwwLcm9vdC1icmlkZ2WCFDuxUi22sYpLlwJY81Wrqy11phcO
MAoGCCqGSM49BAMCA0gAMEUCIEBYYEOsa07TH7E5MJnGw557lVkORgit2Rm1h3B2
sFgDAiEA1Fj/C3AN5psFMjo0//mrQebo0eKd3aWRx+pQY08mk48=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIBzDCCAXOgAwIBAgICEAAwCgYIKoZIzj0EAwIwPDELMAkGA1UEBhMCTkwxFDAS
BgNVBAoMC1NpZ25pZnkgSHVlMRcwFQYDVQQDDA5IdWUgUm9vdCBDQSAwMTAgFw0y
NTAyMjUwMDAwMDBaGA8yMDUwMTIzMTIzNTk1OVowPDELMAkGA1UEBhMCTkwxFDAS
BgNVBAoMC1NpZ25pZnkgSHVlMRcwFQYDVQQDDA5IdWUgUm9vdCBDQSAwMTBZMBMG
ByqGSM49AgEGCCqGSM49AwEHA0IABFfOO0jfSAUXGQ9kjEDzyBrcMQ3ItyA5krE+
cyvb1Y3xFti7KlAad8UOnAx0FBLn7HZrlmIwm1QnX0fK3LPM13mjYzBhMB0GA1Ud
DgQWBBTF1pSpsCASX/z0VHLigxU2CAaqoTAfBgNVHSMEGDAWgBTF1pSpsCASX/z0
VHLigxU2CAaqoTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggq
hkjOPQQDAgNHADBEAiAk7duT+IHbOGO4UUuGLAEpyYejGZK9Z7V9oSfnvuQ5BQIg
IYSgwwxHXm73/JgcU9lAM6c8Bmu3UE3kBIUwBs1qXFw=
-----END CERTIFICATE-----
"""
