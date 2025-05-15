import Testing
import Foundation
import TSKit_Networking
import TSKit_Networking_Alamofire

struct AlamofireNetworkServiceTests {

    @Test
    func testHeaders() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [MockURLProtocol.withRequestHandler { request in
            (response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: request.allHTTPHeaderFields)!,
             data: Data())
        }]
        let service = AlamofireNetworkService(configuration: Configuration(sessionConfiguration: session), comparator: nil, log: nil)

        let headers = try await withCheckedThrowingContinuation { continuation in
            do {
                let call = try #require(service.builder(for: HeaderRequest()).response(HeaderResponse.self, handler: { response in
                    continuation.resume(returning: response.response.allHeaderFields)
                }).make())
                service.request(call)
            } catch {
                continuation.resume(throwing: error)
            }
        } as! [String: String]

        #expect(headers == ["request": "request", "another": "another"])
    }
}

struct Configuration: AnyNetworkServiceConfiguration {

    var sessionConfiguration: URLSessionConfiguration

    let host: String = "localhost"

    var headers: [String : String]? = ["test": "test", "another": "another"]
}

struct HeaderResponse: AnyResponse {

    static var kind = ResponseKind.data

    init(response: HTTPURLResponse, body: Any?) throws {
        self.response = response
    }
    
    let response: HTTPURLResponse
}

struct HeaderRequest: AnyRequestable {
    let method = RequestMethod.get

    let path = "get_headers"

    var headers: [String : String]? = ["request": "request"]

    var ignoredDefaultHeaders: Set<String> = ["test"]
}


/// Class that allows to intercept requests and react to them accordingly.
final class MockURLProtocol: URLProtocol {

    private static var canInitWithRequest: ((URLRequest) -> Bool)?

    private static var canInitWithTask: ((URLSessionTask) -> Bool)?

    private static var canonicalRequest: ((URLRequest) -> URLRequest)?

    private static var handleRequest: ((URLRequest) async throws -> (response: URLResponse, data: Data)?)?

    private var loadingTask: Task<Void, Never>?

    static func withCanInit(_ canInit: ((URLRequest) -> Bool)?) -> MockURLProtocol.Type {
        self.canInitWithRequest = canInit
        return self
    }

    static func withCanInit(_ canInit: ((URLSessionTask) -> Bool)?) -> MockURLProtocol.Type {
        self.canInitWithTask = canInit
        return self
    }

    static func withCanonicalRequest(_ canonicalRequest: ((URLRequest) -> URLRequest)?) -> MockURLProtocol.Type {
        self.canonicalRequest = canonicalRequest
        return self
    }

    /// Sets a handler that will intercept `URLRequest`, giving an opporunity to stub, delay, forward or cancel the request.
    ///
    /// - To **stub** the response for received `URLRequest` `handler` must return a pair of `URLResponse` and `Data`.
    /// - To **delay** the request `handler` can use `Task.sleep`.
    /// - To **forward** the request `handler` should return `nil`. Only FileURLs are supported.
    /// - To **cancel** the request `handler` should throw an `Error`.
    static func withRequestHandler(_ handler: ((URLRequest) async throws -> (response: URLResponse, data: Data)?)?) -> MockURLProtocol.Type {
        self.handleRequest = handler
        return self
    }

    override class func canInit(with request: URLRequest) -> Bool {
        canInitWithRequest?(request) ?? request.url?.isFileURL ?? false
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        canInitWithTask?(task) ?? true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        canonicalRequest?(request) ?? request
    }

    override func startLoading() {
        loadingTask = Task {
            if let handleRequest = Self.handleRequest {
                do {
                    if let result = try await handleRequest(request) {
                        client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: result.data)
                        client?.urlProtocolDidFinishLoading(self)
                    } else {
                        doTheLoading()
                    }
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            } else {
                doTheLoading()
            }
        }
    }

    private func doTheLoading() {
        guard let url = request.url, url.isFileURL else {
            client?.urlProtocol(self, didFailWithError: CancellationError())
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}
