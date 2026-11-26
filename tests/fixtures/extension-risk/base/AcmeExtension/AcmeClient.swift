import Foundation
import TunaKit

struct AcmeClient {
  static let baseURL = URL(string: "https://api.acme.com/v1")!
  let session = URLSession(configuration: .ephemeral)

  func itemsURL() -> URL {
    Self.baseURL.appending(path: "items")
  }
}
