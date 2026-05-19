import Foundation
import EidKit

final class URLSessionRelayTransport: NfcRelayTransport {

    private var task: URLSessionWebSocketTask?
    private var sdkFrameHandler: ((String) -> Void)?
    private var preConnectContinuation: CheckedContinuation<String, Error>?

    // Called before attestation — opens WebSocket, buffers incoming frames
    func connectForAttestation(url: URL) async throws {
        let t = URLSession.shared.webSocketTask(with: url)
        self.task = t
        t.resume()
        receiveLoop(task: t)
    }

    // Waits for the next buffered pre-connect frame
    func receiveFrame() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            preConnectContinuation = continuation
        }
    }

    // NfcRelayTransport — called by EidKit.relay()
    func connect(url: URL, onFrame: @escaping (String) -> Void) async throws {
        if task != nil {
            // Already connected via connectForAttestation — just register SDK handler
            sdkFrameHandler = onFrame
            return
        }
        let t = URLSession.shared.webSocketTask(with: url)
        self.task = t
        sdkFrameHandler = onFrame
        t.resume()
        receiveLoop(task: t)
    }

    func sendFrame(_ json: String) throws {
        guard let t = task else { throw URLError(.badURL) }
        t.send(.string(json)) { _ in }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard case .success(let msg) = result, case .string(let s) = msg else { return }
            if let handler = self.sdkFrameHandler {
                handler(s)
            } else if let cont = self.preConnectContinuation {
                self.preConnectContinuation = nil
                cont.resume(returning: s)
            }
            self.receiveLoop(task: task)
        }
    }
}
