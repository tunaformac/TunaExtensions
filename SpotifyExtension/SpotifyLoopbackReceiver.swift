import Foundation
import Network

/// Waits for one OAuth redirect on 127.0.0.1 at a port the system picks, answers the browser
/// with a short page, and hands back the redirect URL. Only loopback connections are accepted.
final class SpotifyLoopbackReceiver: @unchecked Sendable {
  let port: UInt16

  private let path: String
  private let listener: NWListener
  private let queue: DispatchQueue
  private var continuation: CheckedContinuation<URL, Error>?
  private var result: Result<URL, Error>?

  private init(listener: NWListener, port: UInt16, path: String, queue: DispatchQueue) {
    self.listener = listener
    self.port = port
    self.path = path
    self.queue = queue
  }

  static func start(path: String) async throws -> SpotifyLoopbackReceiver {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.allowLocalEndpointReuse = true
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw SpotifySignInError.listenerFailed(error.localizedDescription)
    }
    let queue = DispatchQueue(label: "com.tuna.spotify.loopback")

    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      // State updates arrive on the serial `queue`, so this flag needs no lock.
      let once = ResumeOnce()
      listener.stateUpdateHandler = { state in
        guard !once.resumed else { return }
        switch state {
        case .ready:
          once.resumed = true
          if let port = listener.port?.rawValue {
            continuation.resume(returning: port)
          } else {
            continuation.resume(throwing: SpotifySignInError.listenerFailed("No port"))
          }
        case .failed(let error):
          once.resumed = true
          continuation.resume(throwing: SpotifySignInError.listenerFailed(error.localizedDescription))
        case .cancelled:
          once.resumed = true
          continuation.resume(throwing: CancellationError())
        default:
          break
        }
      }
      listener.newConnectionHandler = { $0.cancel() }
      listener.start(queue: queue)
    }

    let receiver = SpotifyLoopbackReceiver(listener: listener, port: port, path: path, queue: queue)
    listener.stateUpdateHandler = { [weak receiver] state in
      if case .failed(let error) = state {
        receiver?.finish(.failure(SpotifySignInError.listenerFailed(error.localizedDescription)))
      }
    }
    listener.newConnectionHandler = { [weak receiver] connection in
      receiver?.handle(connection)
    }
    return receiver
  }

  func waitForCallback(timeout: TimeInterval) async throws -> URL {
    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(SpotifySignInError.timedOut))
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          if let result = self.result {
            continuation.resume(with: result)
          } else {
            self.continuation = continuation
          }
        }
      }
    } onCancel: {
      queue.async { self.finish(.failure(CancellationError())) }
    }
  }

  func stop() {
    listener.cancel()
  }

  // Runs on `queue`.
  private func finish(_ outcome: Result<URL, Error>) {
    guard result == nil else { return }
    result = outcome
    continuation?.resume(with: outcome)
    continuation = nil
  }

  private func handle(_ connection: NWConnection) {
    guard case .hostPort(let host, _) = connection.endpoint, Self.isLoopback(host) else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    receiveRequest(on: connection, buffer: Data())
  }

  private func receiveRequest(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return connection.cancel() }
      var buffer = buffer
      if let data { buffer.append(data) }
      let text = String(decoding: buffer, as: UTF8.self)
      guard text.contains("\r\n") || isComplete || error != nil || buffer.count >= 16 * 1024 else {
        return self.receiveRequest(on: connection, buffer: buffer)
      }

      guard let url = Self.callbackURL(fromRequest: text, port: self.port, path: self.path) else {
        return Self.respond(on: connection, status: "404 Not Found", body: "Not found.")
      }
      let failed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .contains { $0.name == "error" } == true
      Self.respond(
        on: connection,
        status: "200 OK",
        body: failed
          ? "Spotify sign-in didn’t finish. You can close this tab and try again from Tuna."
          : "Signed in to Spotify. You can close this tab and go back to Tuna."
      )
      self.finish(.success(url))
    }
  }

  /// The redirect URL from an HTTP request line like `GET /callback?code=… HTTP/1.1`, or nil
  /// when the request isn't a GET for `path`.
  static func callbackURL(fromRequest request: String, port: UInt16, path: String) -> URL? {
    guard let line = request.components(separatedBy: "\r\n").first else { return nil }
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
    guard let url = URL(string: "http://\(SpotifyAuth.redirectHost):\(port)\(parts[1])"),
      url.path == path
    else { return nil }
    return url
  }

  private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
    switch host {
    case .ipv4(let address): return address.isLoopback
    case .ipv6(let address): return address.isLoopback
    default: return false
    }
  }

  private static func respond(on connection: NWConnection, status: String, body: String) {
    let html = """
      <!doctype html><meta charset="utf-8"><title>Tuna</title>
      <body style="font:15px -apple-system,sans-serif;margin:4em auto;max-width:28em;text-align:center">
      <p>\(body)</p></body>
      """
    let response =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed { _ in connection.cancel() }
    )
  }
}

private final class ResumeOnce: @unchecked Sendable {
  var resumed = false
}
