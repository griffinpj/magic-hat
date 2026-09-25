//
//  HTTPClient.swift
//  magic-hat
//
//  Thin transport layer shared by all API clients. Owns request building,
//  required headers, rate-limit gating, and JSON decoding so individual
//  clients only describe endpoints. Nothing Scryfall-specific lives here
//  except the default User-Agent, which callers can override.
//

import Foundation

enum HTTPError: Error, LocalizedError {
    case badURL
    case badStatus(Int, Data)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid URL."
        case .badStatus(let code, _): return "Server returned status \(code)."
        case .decoding(let e): return "Failed to decode response: \(e.localizedDescription)"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        }
    }
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

nonisolated struct HTTPClient {
    /// Accurate User-Agent per Scryfall requirements.
    let userAgent: String
    let accept: String
    /// Nil means `URLSession.shared`, looked up at the first request rather
    /// than here: the first touch of the shared session initialises
    /// CFNetwork, and dyld's lazy binding of it ran 8.8s on the main
    /// thread at launch when this initialiser ran from `SearchView.init`
    /// (`ScryfallClient.shared`). LaunchPrewarm.network does that touch on
    /// a background thread instead.
    private let customSession: URLSession?
    var session: URLSession { customSession ?? .shared }

    init(
        userAgent: String = "MagicHat/1.0",
        accept: String = "application/json;q=0.9,*/*;q=0.8",
        session: URLSession? = nil
    ) {
        self.userAgent = userAgent
        self.accept = accept
        self.customSession = session
    }

    /// Issues a request after waiting on the rate limiter, decoding the
    /// response body into `T`.
    func request<T: Decodable & Sendable>(
        _ type: T.Type,
        url: URL,
        method: HTTPMethod = .get,
        body: Data? = nil,
        rateLimit category: RateLimitCategory
    ) async throws -> T {
        let data = try await requestData(
            url: url, method: method, body: body, rateLimit: category
        )
        return try await Self.decode(T.self, from: data)
    }

    /// Decoding runs on the global executor, never the caller's actor.
    /// With approachable concurrency a nonisolated async function runs on
    /// the *caller's* actor, and every client here is called from the main
    /// actor — so a 175-card search page, a 10k-name catalog or a
    /// hydration batch was being parsed on the main thread, right under
    /// the keyboard. `@concurrent` opts this one step out.
    @concurrent
    private static func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(error)
        }
    }

    /// Issues a request and returns raw bytes (used for images). On the
    /// global executor: with approachable concurrency a nonisolated async
    /// function runs on the caller's actor, and the callers are on the
    /// main actor — so building the request and starting the transfer, and
    /// CFNetwork's first-use setup, used to run there.
    @concurrent
    func requestData(
        url: URL,
        method: HTTPMethod = .get,
        body: Data? = nil,
        rateLimit category: RateLimitCategory
    ) async throws -> Data {
        await RateLimiter.shared.wait(for: category)

        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return data
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPError.badStatus(http.statusCode, data)
            }
            return data
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport(error)
        }
    }
}
