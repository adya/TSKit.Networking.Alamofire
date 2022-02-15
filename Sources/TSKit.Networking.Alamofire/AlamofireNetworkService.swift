// - Since: 01/20/2018
// - Author: Arkadii Hlushchevskyi
// - Copyright: © 2021. Arkadii Hlushchevskyi.
// - Seealso: https://github.com/adya/TSKit.Networking.Alamofire/blob/master/LICENSE.md

import Foundation
import Alamofire
import TSKit_Networking
import TSKit_Core
import TSKit_Log

public class AlamofireNetworkService: AnyNetworkService {

    public var backgroundSessionCompletionHandler: (() -> Void)? {
        get {
            manager.backgroundCompletionHandler
        }
        set {
            manager.backgroundCompletionHandler = newValue
        }
    }
    
    public var interceptors: [AnyNetworkServiceInterceptor]
    
    public var recoverers: [AnyNetworkServiceRecoverer]

    private let manager: Alamofire.SessionManager

    private let configuration: AnyNetworkServiceConfiguration

    private var log: AnyLogger?
    
    /// Flag determining what type of session tasks should be used.
    /// When working in background all requests are handled by `URLSessionDownloadTask`s,
    /// otherwise `URLSessionDataTask` will be used.
    private var isBackground: Bool {
        manager.session.configuration.networkServiceType == .background
    }

    private var defaultHeaders: [String : String]? {
        configuration.headers
    }

    public required init(configuration: AnyNetworkServiceConfiguration,
                         recoverers: [AnyNetworkServiceRecoverer] = [],
                         interceptors: [AnyNetworkServiceInterceptor] = [],
                         log: AnyLogger?) {
        manager = Alamofire.SessionManager(configuration: configuration.sessionConfiguration)
        manager.startRequestsImmediately = false
        self.configuration = configuration
        self.recoverers = recoverers
        self.interceptors = interceptors
        self.log = log
        manager.adapter = self
        manager.retrier = self
    }
    
    public func builder(for request: AnyRequestable) -> AnyRequestCallBuilder {
        AlamofireRequestCallBuilder(request: request)
    }

    public func request(_ requestCalls: [AnyRequestCall],
                        option: ExecutionOption,
                        queue: DispatchQueue = .global(),
                        completion: RequestCompletion? = nil) {
        let calls = requestCalls.map(supportedCall).filter { call in
            let isAllowed = self.interceptors.allSatisfy { $0.intercept(call: call) }
            
            if !isAllowed { log?.warning("At least one interceptor has denied \(call.request)") }
            
            return isAllowed
        }
        addActiveCalls(calls)
        var capturedResult: EmptyResponse = .success(())
        guard !calls.isEmpty else {
            completion?(capturedResult)
            return
        }
        
        switch option {
        case .executeAsynchronously(let ignoreFailures):
            let group = completion != nil ? DispatchGroup() : nil
            var requests: [RequestWrapper] = []
            requests = calls.map {
                process($0) { result in
                    group?.leave()
                    if !ignoreFailures,
                       case .failure = result,
                       case .success = capturedResult {
                        requests.forEach { $0.request?.cancel() }
                        capturedResult = result
                    }
                }
            }
            let weakRequests = requests.map(Weak<RequestWrapper>.init(object:))
            requests.forEach {
                group?.enter()
                $0.onReady {
                    $0.resume()
                }.onFail { error in
                    group?.leave()
                    if !ignoreFailures,
                       case .success = capturedResult {
                        weakRequests.forEach { $0.object?.request?.cancel() }
                        capturedResult = .failure(error)
                    }
                }
            }
            group?.notify(queue: queue) {
                completion?(capturedResult)
            }

        case .executeSynchronously(let ignoreFailures):

            func executeNext(_ call: AlamofireRequestCall, at index: Int) {
                process(call) { result in
                    if !ignoreFailures,
                       case .failure = result,
                       case .success = capturedResult {
                        completion?(result)
                        return
                    }

                    let nextIndex = index + 1
                    guard nextIndex < calls.count else {
                        completion?(.success(()))
                        return
                    }

                    executeNext(calls[nextIndex], at: nextIndex)
                }.onReady {
                    $0.resume()
                }
                 .onFail {
                     if !ignoreFailures,
                        case .success = capturedResult {
                         completion?(.failure($0))
                     }
                 }
            }

            executeNext(calls.first!, at: 0)
        }
    }

    /// Verifies that specified call is the one that is supported by service.
    private func supportedCall(_ call: AnyRequestCall) -> AlamofireRequestCall {
        guard let supportedCall = call as? AlamofireRequestCall else {
            let message = "'\(AlamofireNetworkService.self)' does not support '\(type(of: call))'. You should use '\(AlamofireRequestCall.self)'"
            log?.severe(message)
            preconditionFailure(message)
        }
        return supportedCall
    }
    
    /// Calls that are being processed currently.
    @AsyncSynchronized(synchronizer: ConcurrentQueueSynchronizer())
    private var activeCalls: [AlamofireRequestCall] = []
    
    /// Calls that are pending recovery.
    @AsyncSynchronized(synchronizer: ConcurrentQueueSynchronizer())
    private var pendingRecoveries = RecoveryItemDictionary()
    
    /// Finds an active `AlamofireRequestCall` that corresponds to given `request`.
    private func activeCall(for request: Alamofire.Request) -> AlamofireRequestCall? {
        activeCalls.first(where: { $0.originalRequest == request.task?.originalRequest })
    }
    
    private func addActiveCalls(_ calls: [AlamofireRequestCall]) {
        activeCalls += calls
    }
    
    private func removeActiveCall(_ call: AlamofireRequestCall) {
        activeCalls.removeFirst(where: { $0.originalRequest == call.originalRequest })
    }
}

// MARK: - Multiple requests.
private extension AlamofireNetworkService {

    /// Constructs appropriate `Alamofire`'s request object for given `call`.
    /// - Note: The request object must be resumed manually.
    /// - Parameter call: A call for which request object will be constructed.
    /// - Parameter completion: A closure to be called upon receiving response.
    /// - Returns: Constructed `Alamofire`'s request object.
    func process(_ call: AlamofireRequestCall,
                 _ completion: @escaping RequestCompletion) -> RequestWrapper {

        let method = HTTPMethod(call.request.method)
        let encoding = call.request.encoding.alamofireEncoding(withOptions: call.request.encodingOptions ?? configuration.encodingOptions)
        let headers = constructHeaders(withRequest: call.request)
        let url: String = constructUrl(withRequest: call.request)

        if let request = call.request as? AnyMultipartRequestable {
            let wrapper = RequestWrapper()
            manager.upload(multipartFormData: { [weak self] formData in
                request.parameters?.forEach {
                    self?.appendParameter($0.1, named: $0.0, to: formData, using: request.parametersDataEncoding)
                }
                request.files?.forEach { file in
                    if let urlFile = file as? MultipartURLFile {
                        formData.append(urlFile.url,
                                        withName: urlFile.name,
                                        fileName: urlFile.fileName,
                                        mimeType: urlFile.mimeType)
                    } else if let dataFile = file as? MultipartDataFile {
                        formData.append(dataFile.data,
                                        withName: dataFile.name,
                                        fileName: dataFile.fileName,
                                        mimeType: dataFile.mimeType)
                    } else if let streamFile = file as? MultipartStreamFile {
                        formData.append(streamFile.stream,
                                        withLength: streamFile.length,
                                        name: streamFile.name,
                                        fileName: streamFile.fileName,
                                        mimeType: streamFile.mimeType)
                    } else {
                        let message = "Unsupported `AnyMultipartFile` type: \(type(of: file))"
                        self?.log?.severe(message)
                        preconditionFailure(message)
                    }
                }
            },
                           to: url,
                           method: method,
                           headers: headers,
                           encodingCompletion: { [weak self] encodingResult in
                               switch encodingResult {
                                case .success(let request, _, _):
                                    self?.appendProgress(request, queue: call.queue) { [weak call] progress in
                                        call?.progress.forEach { $0(progress) }
                                    }.appendResponse(request, call: call, completion: completion)
                                    wrapper.request = request
                                    call.token = request
                                    
                                case .failure(let error):
                                    call.errorHandler?.handle(request: call.request,
                                                              response: nil,
                                                              error: error,
                                                              sessionError: error.asAFError?.underlyingError,
                                                              reason: .encodingFailure,
                                                              body: nil)
                                    wrapper.error = .init(request: request,
                                                          response: nil,
                                                          error: error,
                                                          sessionError: error.asAFError?.underlyingError,
                                                          reason: .encodingFailure,
                                                          body: nil)
                               }
                           })
            return wrapper
        } else if call.request is AnyFileRequestable || isBackground {
            let destination: DownloadRequest.DownloadFileDestination = { [weak self] tempFileURL, _ in
                let directory = self?.configuration.sessionTemporaryFilesDirectory
                    ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? {
                        if #available(iOS 10.0, *) {
                            return FileManager.default.temporaryDirectory
                        } else {
                            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                        }
                    }()
            
                return (directory.appendingPathComponent(tempFileURL.lastPathComponent),
                        [.removePreviousFile, .createIntermediateDirectories])
            }
            
            let request = manager.download(url,
                                           method: method,
                                           parameters: call.request.parameters,
                                           encoding: encoding,
                                           headers: headers,
                                           to: destination)
            call.token = request
            appendProgress(request, queue: call.queue) { [weak call] progress in
                call?.progress.forEach { $0(progress) }
            }.appendResponse(request, call: call, completion: completion)
            return RequestWrapper(request)
        } else {
            let request = manager.request(url,
                                          method: method,
                                          parameters: call.request.parameters,
                                          encoding: encoding,
                                          headers: headers)
            call.token = request
            appendProgress(request, queue: call.queue) { [weak call] progress in
                call?.progress.forEach { $0(progress) }
            }.appendResponse(request, call: call, completion: completion)
            return RequestWrapper(request)
        }
    }
}

// MARK: - Constructing request properties.
private extension AlamofireNetworkService {

    func constructUrl(withRequest request: AnyRequestable) -> String {
        guard !request.path.contains("http") else {
            return request.path
        }

        let host = request.host ?? configuration.host
        
        let path = request.path.hasPrefix("/") ? request.path : "/\(request.path)"
        return "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(path)"
    }
    
    func constructUrl(withRequest request: AnyRequestable) -> URL {
        guard let url = URL(string: (request.host ?? configuration.host)) else {
            let message = "Neither default `host` nor request's `host` had been specified"
            log?.severe(message)
            preconditionFailure(message)
        }
        return url.appendingPathComponent(request.path)
    }

    func constructHeaders(withRequest request: AnyRequestable) -> [String : String] {
        return (defaultHeaders ?? [:]) + (request.headers ?? [:])
    }
}

// MARK: - Constructing multipart Alamofire request.
private extension AlamofireNetworkService {

    func createParameterComponent(_ param: Any, named name: String) -> [(String, String)] {
        var comps = [(String, String)]()
        if let array = param as? [Any] {
            array.forEach {
                comps += self.createParameterComponent($0, named: "\(name)[]")
            }
        } else if let dictionary = param as? [String : Any] {
            dictionary.forEach { key, value in
                comps += self.createParameterComponent(value, named: "\(name)[\(key)]")
            }
        } else {
            comps.append((name, "\(param)"))
        }
        return comps
    }

    func encodeURLParameter(_ param: Any, named name: String, intoUrl url: String) -> String {
        let comps = self.createParameterComponent(param, named: name).map { "\($0)=\($1)" }
        return "\(url)?\(comps.joined(separator: "&"))"
    }

    /// Appends param to the form data.
    func appendParameter(_ param: Any,
                         named name: String,
                         to formData: MultipartFormData,
                         using encoding: String.Encoding) {
        let comps = self.createParameterComponent(param, named: name)
        comps.forEach {
            guard let data = $0.1.data(using: encoding) else {
                print("\(type(of: self)): Failed to encode parameter '\($0.0)'")
                return
            }
            formData.append(data, withName: $0.0)
        }
    }
}

// MARK: - Constructing Alamofire response.
private extension AlamofireNetworkService {

    @discardableResult
    func appendProgress(_ aRequest: Alamofire.DownloadRequest,
                        queue: DispatchQueue,
                        progressCompletion: RequestProgressCompletion? = nil) -> Self {
        guard let progressCompletion = progressCompletion else { return self }
        aRequest.downloadProgress(queue: queue) { (progress) in
            progressCompletion(progress)
        }
        return self
    }

    @discardableResult
    func appendProgress(_ aRequest: Alamofire.DataRequest,
                        queue: DispatchQueue,
                        progressCompletion: RequestProgressCompletion? = nil) -> Self {
        guard let progressCompletion = progressCompletion else { return self }
        aRequest.downloadProgress(queue: queue) { (progress) in
            progressCompletion(progress)
        }
        return self
    }
    
    @discardableResult
    func appendProgress(_ aRequest: Alamofire.UploadRequest,
                        queue: DispatchQueue,
                        progressCompletion: RequestProgressCompletion? = nil) -> Self {
        guard let progressCompletion = progressCompletion else { return self }
        aRequest.uploadProgress(queue: queue) { (progress) in
            progressCompletion(progress)
        }
        return self
    }

    @discardableResult
    func appendResponse(_ aRequest: Alamofire.DataRequest,
                        call: AlamofireRequestCall,
                        completion: @escaping RequestCompletion) -> Self {
        var result: EmptyResponse!
        
        /// Captures success if at least one handler returned success otherwise first error.
        func setResult(_ localResult: EmptyResponse) {
            guard result != nil else {
                result = localResult
                return
            }
            
            guard case .success = localResult,
                  case .failure = result! else { return }
            
            result = localResult
        }
        
        aRequest.validate(statusCode: call.request.statusCodes)
        
        let kinds = Set(call.handlers.map { $0.responseType.kind })
        
        let handlingGroup = DispatchGroup()
        
        kinds.forEach { kind in
            handlingGroup.enter() // enter group for each scheduled response.
            switch kind {
                case .json:
                    aRequest.responseJSON(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: $0.data,
                                                         kind: .json,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                    }
                
                case .data, .file:
                    if kind == .file {
                        log?.warning(tag: self)("Files are not supported for `AnyRequestable`. Use `AnyFileRequestable` to utilize `ResponseKind.file`. Handling will fall back to `ResponseKind.data`.")
                    }
                    aRequest.responseData(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: $0.data,
                                                         kind: .data,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
                
                case .string:
                    aRequest.responseString(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: $0.data,
                                                         kind: .string,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
                    
                case .empty:
                    aRequest.response(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: nil,
                                                         rawData: $0.data,
                                                         kind: .empty,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
            }
        }
            
        handlingGroup.notify(queue: call.queue) {
            completion(result)
        }

        return self
    }

    @discardableResult
    func appendResponse(_ aRequest: Alamofire.DownloadRequest,
                        call: AlamofireRequestCall,
                        completion: @escaping RequestCompletion) -> Self {
        var result: EmptyResponse!
        
        /// Captures success if at least one handler returned success otherwise first error.
        func setResult(_ localResult: EmptyResponse) {
            guard result != nil else {
                result = localResult
                return
            }
            
            guard case .success = localResult,
                case .failure = result! else { return }
            
            result = localResult
        }
        
        aRequest.validate(statusCode: call.request.statusCodes)
        
        let kinds = Set(call.handlers.map { $0.responseType.kind })
        
        let handlingGroup = DispatchGroup()
        
        kinds.forEach {
            handlingGroup.enter() // enter group for each scheduled response.
            switch $0 {
                case .json:
                    aRequest.responseJSON(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: nil,
                                                         kind: .json,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                    }
                
                case .data:
                    aRequest.responseData(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: nil,
                                                         kind: .data,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
                
                case .string:
                    aRequest.responseString(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.value,
                                                         rawData: nil,
                                                         kind: .string,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
                    
                case .file:
                    aRequest.response(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: $0.destinationURL,
                                                         rawData: nil,
                                                         kind: .file,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                    }
                
                case .empty:
                    aRequest.response(queue: call.queue) { [weak self] in
                        guard let self = self else { return }
                        let result = self.handleResponse($0.response,
                                                         error: $0.error,
                                                         value: nil,
                                                         rawData: nil,
                                                         kind: .empty,
                                                         call: call)
                        setResult(result)
                        handlingGroup.leave()
                }
            }
        }
            
        handlingGroup.notify(queue: call.queue) {
            completion(result)
        }
        return self
    }

    private func handleResponse(_ response: HTTPURLResponse?,
                                error: Error?,
                                value: Any?,
                                rawData: Data?,
                                kind: ResponseKind,
                                call: AlamofireRequestCall) -> EmptyResponse {
        defer { removeActiveCall(call) }
        guard call.token != nil else {
            log?.verbose(tag: self)("Request has been cancelled and will be ignored")
            return .success(())
        }
        
        guard let httpResponse = response else {
            log?.severe("HTTP Response was not specified. Response will be ignored")
            call.errorHandler?.handle(request: call.request,
                                      response: nil,
                                      error: error,
                                      sessionError: error?.asAFError?.underlyingError,
                                      reason: .unreachable,
                                      body: nil)
        
            return .failure(.init(request: call.request,
                                  response: nil,
                                  error: error,
                                  sessionError: error?.asAFError?.underlyingError,
                                  reason: .unreachable,
                                  body: nil))
        }
        
        // Reconstruct body from raw data received from server based on response kind.
        let value = value ?? { () -> Any? in
            guard let data = rawData else { return nil }
            switch kind {
                case .string: return String(data: data, encoding: .utf8)
                case .json: return try? JSONSerialization.jsonObject(with: data, options: [])
                case .data, .empty: return data
                case .file: return value as? URL
            }
        }()
        
        let shouldProcess = self.interceptors.allSatisfy { $0.intercept(call: call, response: httpResponse, body: value) }
        
        // If any interceptor blocked response processing then exit.
        guard shouldProcess else {
            log?.warning("At least one interceptor has blocked response for \(call.request)")
           
            call.errorHandler?.handle(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      sessionError: error?.asAFError?.underlyingError,
                                      reason: .skipped,
                                      body: value)
            
            return .failure(.init(request: call.request,
                                  response: httpResponse,
                                  error: error,
                                  sessionError: error?.asAFError?.underlyingError,
                                  reason: .skipped,
                                  body: value))
        }
        
        let status = httpResponse.statusCode

        /// Handlers that can accept response's status code.
        let statusHandlers = call.handlers.filter { $0.statuses.contains(status) }
        
        /// Handlers that both can accept response's status code and have expected kind of body.
        let validHandlers = statusHandlers.filter { $0.responseType.kind == kind }
        
        // If no handlers attached for given status code with matching kind, produce an error
        guard !validHandlers.isEmpty else {
            
            // If status handlers are not empty it means that `handleResponse` is trigerred by not matching `kind`.
            // Ideally this should not happen, but at the moment there is no way to attach status-based handlers
            // only when needed because status codes are not known until later when we got response from server.
            // In such case we silently succeed current call as it will be handled by another kind.
            // Otherwise it means that there is no handlers for that status code at all so we should trigger necessary global handlers.
            guard statusHandlers.isEmpty else {
                return .success(())
            }
            
            // If error was received then return generic `.httpError` result
            // Otherwise silently succeed the call as no one is interested in processing result
            guard let error = error else {
                return .success(())
            }
            
            call.errorHandler?.handle(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      sessionError: error.asAFError?.underlyingError,
                                      reason: .httpError,
                                      body: value)
            return .failure(.init(request: call.request,
                                  response: httpResponse,
                                  error: error,
                                  sessionError: error.asAFError?.underlyingError,
                                  reason: .httpError,
                                  body: value))
        }
        
        // For all valid handlers construct and deliver corresponding `AnyResponse` objects
        for responseHandler in validHandlers {
            
            /// If there is no error then simply construct  response object and deliver it to handler.
            guard let error = error else {
                do {
                    let response = try responseHandler.responseType.init(response: httpResponse, body: value)
                    responseHandler.handler(response)
                } catch let constructionError {
                    log?.error("Failed to construct response of type '\(responseHandler.responseType)' using body: \(value ?? "no body")")
                    call.errorHandler?.handle(request: call.request,
                                              response: httpResponse,
                                              error: constructionError,
                                              sessionError: nil,
                                              reason: .deserializationFailure,
                                              body: value)
                    return .failure(.init(request: call.request,
                                          response: httpResponse,
                                          error: constructionError,
                                          sessionError: nil,
                                          reason: .deserializationFailure,
                                          body: value))
                }
                continue
            }
            
            // If an error was received and it is a validation error we need to ensure
            // that it was validation of status code that failed (and not contentType or other validatable headers).
            // And if it is status code then deliver Response object to any subscribed halders.
            if let error = error as? AFError,
                error.isResponseValidationError,
                !call.request.statusCodes.contains(status) {
                do {
                    let response = try responseHandler.responseType.init(response: httpResponse, body: value)
                    responseHandler.handler(response)
                } catch let constructionError {
                    log?.error("Failed to construct response of type '\(responseHandler.responseType)' using body: \(value ?? "no body")")
                    call.errorHandler?.handle(request: call.request,
                                              response: httpResponse,
                                              error: constructionError,
                                              sessionError: nil,
                                              reason: .deserializationFailure,
                                              body: value)
                    return .failure(.init(request: call.request,
                                          response: httpResponse,
                                          error: constructionError,
                                          sessionError: nil,
                                          reason: .deserializationFailure,
                                          body: value))
                }
            } else {
                // If it is any other error then report the error.
                call.errorHandler?.handle(request: call.request,
                                          response: httpResponse,
                                          error: error,
                                          sessionError: error.asAFError?.underlyingError,
                                          reason: .httpError,
                                          body: value)
                return .failure(.init(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      sessionError: error.asAFError?.underlyingError,
                                      reason: .httpError,
                                      body: value))
            }
        }
        
        // By the end of the loop report successful handling.
        return .success(())
    }
}

// MARK: - Recovery support
private extension AlamofireNetworkService {
    
    func recoverCall(_ call: AlamofireRequestCall,
                     with response: HTTPURLResponse?,
                     after error: Error,
                     using recoverer: AnyNetworkServiceRecoverer,
                     completion: @escaping RequestRetryCompletion) {
        guard let request = call.originalRequest,
              pendingRecoveries[request] == nil else { return completion(false, 0) }

        pendingRecoveries[request] = .init(recoverer: recoverer, call: call)
        log?.verbose(tag: self)("Recovering request \(call.request)")
        recoverer.recover(call: call, response: response, error: error as? URLError, in: self) { [weak self] isRecovered in
            if isRecovered {
                call.recoveryAttempts += 1
                self?.log?.verbose(tag: self)("Retrying request \(call.request). Attempt #\(call.recoveryAttempts). Retrying after response: \(String(describing: response)); error: \(error)")
            } else {
                self?.log?.verbose(tag: self)("No more retries for request \(call.request). Failing with response: \(String(describing: response)); error: \(error)")
                self?.pendingRecoveries[request] = nil
            }
            completion(isRecovered, isRecovered ? 1 : 0)
        }
    }

    /// Performs
    func updateRequestAfterRecovery(_ request: inout URLRequest) {
        guard let item = pendingRecoveries.removeValue(forKey: request) else { return }
        
        item.recoverer.update(request: &request,
                              afterRecovering: item.call,
                              in: self)
    }
}

// MARK: - RequestRetrier
extension AlamofireNetworkService: RequestRetrier {
    
    public func should(_ manager: SessionManager,
                       retry request: Request,
                       with error: Error,
                       completion: @escaping RequestRetryCompletion) {
        guard let requestCall = activeCall(for: request) else {
            return completion(false, 0)
        }
        
        guard let recoverer = recoverers.first(where: { $0.canRecover(call: requestCall, response: request.response, error: error as? URLError, in: self) }) else {
            return completion(false, 0)
        }
        
        recoverCall(requestCall, with: request.response, after: error, using: recoverer, completion: completion)
    }
}

// MARK: - RequestAdapter
extension AlamofireNetworkService: RequestAdapter {
    
    public func adapt(_ urlRequest: URLRequest) throws -> URLRequest {
        transform(urlRequest) { request in
            request.timeoutInterval = configuration.timeoutInterval ?? configuration.sessionConfiguration.timeoutIntervalForRequest
            
            updateRequestAfterRecovery(&request)
        }
    }
}

// MARK: - Mapping abstract enums to Alamofire enums.
private extension Alamofire.HTTPMethod {

    init(_ method: RequestMethod) {
        switch method {
        case .get: self = .get
        case .post: self = .post
        case .patch: self = .patch
        case .delete: self = .delete
        case .put: self = .put
        case .head: self = .head
        case .trace: self = .trace
        case .options: self = .options
        }
    }
}

private extension Error {
    
    var asAFError: AFError? {
        self as? AFError
    }
}

private extension TSKit_Networking.ParameterEncoding {

    func alamofireEncoding(withOptions options: TSKit_Networking.ParameterEncoding.Options) -> Alamofire.ParameterEncoding {
        switch self {
        case .json: return JSONEncoding.default
            case .url: return URLEncoding(destination: .methodDependent,
                                      arrayEncoding: options.useBracketsForArrays ? .brackets : .noBrackets,
                                      boolEncoding: options.boolEncoding.alamofireEncoding)
        case .formData: return URLEncoding.default
        case .path: return PathEncoding()
        }
    }
}

private extension TSKit_Networking.ParameterEncoding.Options.BoolEncoding {
    
    var alamofireEncoding: URLEncoding.BoolEncoding {
        switch self {
            case .literal: return .literal
            case .numeric: return .numeric
        }
    }
}

private struct PathEncoding: Alamofire.ParameterEncoding {
    
    func encode(_ urlRequest: URLRequestConvertible, with parameters: Parameters?) throws -> URLRequest {
        var urlRequest = try urlRequest.asURLRequest()
        
        guard let parameters = parameters else { return urlRequest }
        
        guard let url = urlRequest.url,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AFError.parameterEncodingFailed(reason: .missingURL)
        }
        parameters.forEach { (key: String, value: Any) in
            components.path = components.path.replacingOccurrences(of: "$\(key)", with: "\(value)", options: [])
        }
        urlRequest.url = try components.asURL()
        return urlRequest
    }
}

/// A custom struct that mimics Dictionary semantics for `[URLRequest: RecoveryItem]`.
///
/// It is used to implement custom equality logic for `URLRequest`s to only rely on `url` and `httpMethod`.
private struct RecoveryItemDictionary {
    
    private var items: [RecoveryItem] = []
    
    subscript (_ key: URLRequest) -> RecoveryItem? {
        get {
            items.first(where: curry(requestEquals)(key))
        }
        set {
            if let newValue = newValue {
                if items.updateFirst(where: curry(requestEquals)(key), with: newValue) == nil {
                    items.append(newValue)
                }
            } else {
                _ = removeValue(forKey: key)
            }
        }
    }
    
    mutating func removeValue(forKey key: URLRequest) -> RecoveryItem? {
        items.removeFirst(where: curry(requestEquals)(key))
    }
    
    private func requestEquals(_ lhs: URLRequest, _ rhs: RecoveryItem) -> Bool {
        requestEquals(lhs, rhs.call.originalRequest)
    }
    
    private func requestEquals(_ lhs: URLRequest?, _ rhs: URLRequest?) -> Bool {
        lhs?.url == rhs?.url && lhs?.httpMethod == rhs?.httpMethod
    }
}
    
private struct RecoveryItem {
    
    let recoverer: AnyNetworkServiceRecoverer
    
    let call: AlamofireRequestCall
}
