import Foundation
import Quick
import Nimble
import TSKit_Core
import TSKit_Log

import Alamofire

@testable import TSKit_Networking
@testable import TSKit_Networking_Alamofire
//
//class InspectableService: AlamofireNetworkService {
//
//    var retriesCount: UInt = 0
//
//    override func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion) {
//        super.should(manager, retry: request, with: error, completion: {
//            if $0 {
//                self.retriesCount += 1
//                print("RETRYING: \(self.retriesCount)")
//            }
//            completion($0, $1)
//        })
//    }
//}
//
//class MockRecoverer: DeferredRetryRecoverer {
//
//    var recoveryCount: UInt = 0
//
//    override func attemptRecovery(for call: AnyRequestCall, response: HTTPURLResponse?, error: URLError?, in service: AnyNetworkService, _ completion: @escaping RecoveryCompletion) {
//        recoveryCount += 1
//        completion(true)
//    }
//}
//
//class AlamofireNetworkServiceSpec: QuickSpec {
//
//    private func makeCall<ResponseType: AnyResponse>(for request: AnyMockedRequestable.Type,
//                                                     retries: UInt? = nil,
//                                                     response: ResponseType.Type,
//                                                     handler: @escaping (_ response: ResponseType?) -> Void) -> AnyRequestCall {
//        service.builder(for: transform(request.init()) {
//            $0.maximumRecoveryAttempts = retries
//        })
//        .dispatch(to: .global())
//        .response(response) {
//            print($0)
//            handler($0)
//
//        }.error {
//            print($0)
//            handler(nil)
//        }
//        .make()!
//    }
//
//    private func makeCall(for request: AnyMockedRequestable.Type,
//                          retries: UInt? = nil,
//                          handler: @escaping () -> Void) -> AnyRequestCall {
//        makeCall(for: request, retries: retries, response: SuccessResponse.self, handler: { _ in handler() })
//    }
//
//    private func makeStatusCall<T>(for request: T.Type, retries: UInt? = nil, result: @escaping (Bool, Int?) -> Void) -> AnyRequestCall where T: AnyMockedRequestable {
//        service.builder(for: transform(request.init()) {
//            $0.maximumRecoveryAttempts = retries
//        })
//        .dispatch(to: .global())
//        .response(SuccessResponse.self, forStatuses: 200) {
//            result(true, $0.response.statusCode)
//        }.response(FailingResponse.self, forStatuses: 404) {
//            result(true, $0.response.statusCode)
//        }.error { _ in
//            result(false, nil)
//        }.make()!
//    }
//
//    private var service: InspectableService!
//
//    private var retryRecovery: RetryRecoverer!
//
//    private var recoverRecovery: MockRecoverer!
//
//    private var configuration: ForegroundConfiguration!
//
//    override func spec() {
//        let criticalTimeout = DispatchTimeInterval.seconds(10)
//        describe("Foreground alamofire network service") {
//            beforeEach {
//                self.configuration = .init()
//                self.service = InspectableService(configuration: self.configuration,
//                                                  log: transform(Logger()) {
//                    $0.writers = [PrintLogEntryWriter()]
//                })
//                self.retryRecovery = RetryRecoverer()
//                self.recoverRecovery = MockRecoverer()
//            }
//
//            describe("when processing single request") {
//
//                context("with single response handler") {
//                    it("is able to handle successful response") {
//                        waitUntil(timeout: criticalTimeout) { done in
//                            self.makeCall(for: SuccessRequest.self, handler: done) ==> { self.service.request($0) }
//                        }
//                    }
//
//                    it("is able to handle failed response") {
//                        waitUntil(timeout: criticalTimeout) { done in
//                            self.makeCall(for: FailingRequest.self, handler: done) ==> { self.service.request($0) }
//                        }
//                    }
//                }
//
//                context("without response handler") {
//                    it("is able to handle successful response through request completion") {
//                        waitUntil(timeout: criticalTimeout) { done in
//                            self.makeCall(for: SuccessRequest.self, handler: {}) ==> { self.service.request($0) { _ in done() } }
//                        }
//                    }
//
//                    it("is able to handle failed response through request completion") {
//                        waitUntil(timeout: criticalTimeout) { done in
//                            self.makeCall(for: FailingRequest.self, handler: {}) ==> { self.service.request($0) { _ in done() } }
//                        }
//                    }
//                }
//
//                context("with multiple status-based response handlers") {
//
//                    /// Array of received responses
//                    var isSuccess: [Bool] = []
//                    /// Array of received statuses
//                    var receivedStatuses: [Int] = []
//
//                    beforeEach {
//                        isSuccess = []
//                        receivedStatuses = []
//                    }
//
//                    context("and receiving successful response") {
//                        it("should handle it with only SuccessResponse") {
//                            self.service.request(self.makeStatusCall(for: SuccessRequest.self) {
//                                isSuccess.append($0)
//                                if let status = $1 {
//                                    receivedStatuses.append(status)
//                                }
//                            })
//                            expect(isSuccess).toEventually(equal([true]), timeout: criticalTimeout)
//                            expect(receivedStatuses).toEventually(equal([200]), timeout: criticalTimeout)
//                        }
//                    }
//
//                    context("and receiving failing response") {
//                        it("should handle it with only FailingResponse") {
//                            self.service.request(self.makeStatusCall(for: FailingRequest.self) {
//                                isSuccess.append($0)
//                                if let status = $1 {
//                                    receivedStatuses.append(status)
//                                }
//                            })
//                            expect(isSuccess).toEventually(equal([true]), timeout: criticalTimeout)
//                            expect(receivedStatuses).toEventually(equal([404]), timeout: criticalTimeout)
//                        }
//                    }
//                }
//
//                context("that downloads file") {
//                    it("should provide temporary url to the file") {
//                        var file: URL?
//                        self.service.request(self.makeCall(for: FileRequest.self, response: FileResponse.self) {
//                            file = $0?.file
//                            print("Received \(file)")
//                        })
//
//                        expect(file).toNotEventually(beNil(), timeout: criticalTimeout)
//                    }
//                }
//
//                context("and configured retry") {
//                    let retries: UInt = 4
//                    beforeEach {
//                        self.service.recoverers = [self.retryRecovery]
//                        self.service.retriesCount = 0
//                    }
//                    it("should try \(retries) times request") {
//                        let call = self.makeCall(for: FailingRequest.self, retries: retries) {}
//                        var called = false
//                        self.service.request(call) { _ in
//                            called = true
//                        }
//
//                        expect(called).toEventually(beTrue(), timeout: criticalTimeout)
//                        expect(self.service.retriesCount).toEventually(equal(retries), timeout: criticalTimeout)
//                    }
//
//                    it("should not retry request with inappropriate method (POST)") {
//                        self.retryRecovery.retriableMethods = [.get]
//                        let call = self.makeCall(for: NotRetriableMethodFailingRequest.self, retries: retries) {}
//                        var called = false
//                        self.service.request(call) { _ in
//                            called = true
//                        }
//
//                        expect(called).toEventually(beTrue(), timeout: criticalTimeout)
//                        expect(self.service.retriesCount).toEventually(equal(0), timeout: criticalTimeout)
//                    }
//                }
//
//                context("and configured recovery") {
//                    beforeEach {
//                        self.service.recoverers = [self.recoverRecovery]
//                        self.recoverRecovery.recoveryCount = 0
//                        self.recoverRecovery.retriableStatuses = [404]
//                    }
//
//                    it("should recover") {
//                        let call = self.makeCall(for: FailingRequest.self) {}
//                        self.service.request(call)
//
//                        expect(self.recoverRecovery.recoveryCount).toEventually(beGreaterThan(0), timeout: criticalTimeout)
//                    }
//                }
//            }
//
//            describe("when processing multiple requests") {
//                let testingQueue = DispatchQueue(label: "Testing")
//                let requests: [(String, AnyMockedRequestable.Type)] = [("Success 1", SuccessRequest.self),
//                                                                    ("Fail 1", FailingRequest.self),
//                                                                    ("Success 2", SuccessRequest.self),
//                                                                    ("Fail 2", FailingRequest.self)]
//                let requestLabels = requests.map { $0.0 }
//                let failedLabel = "Failed"
//                let completionLabel = "Completed"
//                var calls: [AnyRequestCall]!
//                var steps: [String] = []
//
//                beforeEach {
//                    steps = []
//                    calls = requests.map { pair in
//                        return self.makeCall(for: pair.1) {
//                            testingQueue.sync { steps.append(pair.0) }
//                        }
//                    }
//                }
//                afterEach {
//                    calls.removeAll()
//                }
//
//                describe("synchronously") {
//                    context("and ignores failures") {
//                        let expectedLabels = requests.map { $0.0 }.appending(completionLabel)
//                        it("should be executed in strict order regardless failed reuqests and completed successfuly") {
//                            self.service.request(calls, option: .executeSynchronously(ignoreFailures: true)) {
//                                switch $0 {
//                                case .success: testingQueue.sync { steps.append(completionLabel) }
//                                case .failure: testingQueue.sync { steps.append(failedLabel) }
//                                }
//                            }
//                            expect(steps).toEventually(equal(expectedLabels), timeout: criticalTimeout)
//                        }
//                    }
//
//                    context("and does not ignore failures") {
//                        let expectedLabels = Array(requestLabels[0..<2]).appending(failedLabel)
//                        it("should be executed in strict order and fail after first failed reuqest") {
//                            self.service.request(calls, option: .executeSynchronously(ignoreFailures: false)) {
//                                switch $0 {
//                                case .success: testingQueue.sync { steps.append(completionLabel) }
//                                case .failure: testingQueue.sync { steps.append(failedLabel) }
//                                }
//                            }
//                            expect(steps).toEventually(equal(expectedLabels), timeout: criticalTimeout)
//                        }
//                    }
//                }
//
//                describe("asynchronously") {
//                    context("and ignores failures") {
//                        it("should be executed randomly and completed successfuly regardless failed reuqests") {
//                            self.service.request(calls, option: .executeAsynchronously(ignoreFailures: true)) {
//                                switch $0 {
//                                case .success: testingQueue.sync { steps.append(completionLabel) }
//                                case .failure: testingQueue.sync { steps.append(failedLabel) }
//                                }
//                            }
//                            expect(steps).toEventually(contain(completionLabel), timeout: criticalTimeout)
//                        }
//                    }
//
//                    context("and does not ignore failures") {
//                        it("should be executed randomly and fail after first failed reuqest") {
//                            self.service.request(calls, option: .executeAsynchronously(ignoreFailures: false)) {
//                                switch $0 {
//                                case .success: testingQueue.sync { steps.append(completionLabel) }
//                                case .failure: testingQueue.sync { steps.append(failedLabel) }
//                                }
//                            }
//                            expect(steps).toEventually(contain(failedLabel), timeout: criticalTimeout)
//                        }
//                    }
//                }
//            }
//        }
//    }
//}
//
//private protocol AnyMockedRequestable: AnyRequestable {
//
//    var maximumRecoveryAttempts: UInt? { get set }
//
//    init()
//}
//
//private struct SuccessRequest: AnyMockedRequestable {
//
//    let method = RequestMethod.get
//
//    let path: String = ""
//
//    var maximumRecoveryAttempts: UInt? = nil
//}
//
//private struct NotRetriableMethodFailingRequest: AnyMockedRequestable {
//
//    let method = RequestMethod.post
//
//    let path: String = "not_existed"
//
//    var maximumRecoveryAttempts: UInt? = nil
//}
//
//private struct FailingRequest: AnyMockedRequestable {
//
//    let method = RequestMethod.get
//
//    let path: String = "not_existed"
//
//    var maximumRecoveryAttempts: UInt? = nil
//}
//
//private struct FileRequest: AnyMockedRequestable, AnyFileRequestable {
//
//    let method = RequestMethod.get
//
//    let path = "https://raw.githubusercontent.com/adya/TSKit.Networking.Alamofire/master/Cartfile"
//
//    var maximumRecoveryAttempts: UInt? = nil
//}
//
//private struct FailingResponse: AnyResponse {
//
//    static let kind = ResponseKind.string
//
//    let response: HTTPURLResponse
//
//    init(response: HTTPURLResponse, body: Any?) throws {
//        self.response = response
//    }
//
//}
//
//private struct SuccessResponse: AnyResponse {
//
//    static let kind = ResponseKind.string
//
//    let response: HTTPURLResponse
//
//    init(response: HTTPURLResponse, body: Any?) throws {
//        self.response = response
//    }
//
//}
//
//private struct FileResponse: AnyFileResponse {
//
//    static let kind = ResponseKind.file
//
//    let response: HTTPURLResponse
//
//    let file: URL
//
//    init(response: HTTPURLResponse, body: Any?) throws {
//        guard let url = body as? URL else { throw URLError(.badURL) }
//        self.response = response
//        self.file = url
//    }
//
//}
//
//private class ForegroundConfiguration: AnyNetworkServiceConfiguration {
//
//    var sessionTemporaryFilesDirectory: URL? { nil }
//
//    let host = "https://google.com"
//
//    let sessionConfiguration: URLSessionConfiguration = {
//        let configuration = URLSessionConfiguration.default
//        configuration.timeoutIntervalForRequest = 5
//        return configuration
//    }()
//}
