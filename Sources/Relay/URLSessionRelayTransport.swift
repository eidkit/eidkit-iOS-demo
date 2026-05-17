import Foundation
import EidKit

/// `NfcRelayTransport` implementation using `URLSessionWebSocketTask` (iOS 13+).
///
/// `URLSession` WebSocket tasks are considered connected after `resume()` — there is no
/// explicit open callback. We start the receive loop immediately and return from `connect`
/// once the task is running.
final class URLSessionRelayTransport: NfcRelayTransport {

    private var task: URLSessionWebSocketTask?

    func connect(url: URL, onFrame: @escaping (String) -> Void) async throws {
        let t = URLSession.shared.webSocketTask(with: url)
        self.task = t
        t.resume()
        receiveLoop(task: t, onFrame: onFrame)
    }

    func sendFrame(_ json: String) throws {
        guard let t = task else { throw URLError(.badURL) }
        t.send(.string(json)) { _ in }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receiveLoop(task: URLSessionWebSocketTask, onFrame: @escaping (String) -> Void) {
        task.receive { [weak self] result in
            guard let self, case .success(let msg) = result else { return }
            if case .string(let s) = msg { onFrame(s) }
            self.receiveLoop(task: task, onFrame: onFrame)
        }
    }
}
