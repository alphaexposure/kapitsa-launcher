import Foundation

/// Kapitsa's `/health` answer, `{"status":"ok"}` once the engine is serving. Kapitsa only
/// listens after the model is loaded, so a refused connection means it is still starting.
struct KapitsaStatus: Decodable, Equatable {
    let status: String?

    init(status: String?) { self.status = status }

    var ready: Bool { status == "ok" }
}

protocol KapitsaStatusRequest {
    func cancel()
}

protocol KapitsaStatusFetching {
    @discardableResult
    func fetchStatus(
        configuration: KapitsaConfiguration,
        apiKey: String?,
        completion: @escaping (Result<KapitsaStatus, Error>) -> Void
    ) -> KapitsaStatusRequest
}

enum KapitsaStatusClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid status URL."
        case .invalidResponse: return "Invalid status response."
        case .httpStatus(let code): return "Health check returned HTTP \(code)."
        }
    }
}

private struct NoopStatusRequest: KapitsaStatusRequest {
    func cancel() {}
}

extension URLSessionDataTask: KapitsaStatusRequest {}

/// Fetches one health snapshot. Scheduling and ownership stay in the process controller.
final class KapitsaStatusClient: KapitsaStatusFetching {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchStatus(
        configuration: KapitsaConfiguration,
        apiKey: String?,
        completion: @escaping (Result<KapitsaStatus, Error>) -> Void
    ) -> KapitsaStatusRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = configuration.host == "0.0.0.0" ? "127.0.0.1" : configuration.host
        components.port = configuration.port
        components.path = "/health"
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(KapitsaStatusClientError.invalidURL)) }
            return NoopStatusRequest()
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 6
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let task = session.dataTask(with: request) { [decoder] data, response, error in
            let result: Result<KapitsaStatus, Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                if !(200...299).contains(response.statusCode) {
                    result = .failure(KapitsaStatusClientError.httpStatus(response.statusCode))
                } else if let data {
                    result = Result { try decoder.decode(KapitsaStatus.self, from: data) }
                } else {
                    result = .failure(KapitsaStatusClientError.invalidResponse)
                }
            } else {
                result = .failure(KapitsaStatusClientError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }
}
