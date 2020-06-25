// - Since: 01/20/2018
// - Author: Arkadii Hlushchevskyi
// - Copyright: © 2020. Arkadii Hlushchevskyi.
// - Seealso: https://github.com/adya/TSKit.Networking.Alamofire/blob/master/LICENSE.md

import Alamofire
import TSKit_Networking
import TSKit_Injection
import TSKit_Core
import TSKit_Log

public class AlamofireNetworkService: AnyNetworkService {

    private let log = try? Injector.inject(AnyLogger.self, for: AnyNetworkService.self)

    public var backgroundSessionCompletionHandler: (() -> Void)? {
        get {
            return manager.backgroundCompletionHandler
        }
        set {
            manager.backgroundCompletionHandler = newValue
        }
    }
    
    public var interceptors: [AnyNetworkServiceInterceptor]?

    private let manager: Alamofire.SessionManager

    private let configuration: AnyNetworkServiceConfiguration

    /// Flag determining what type of session tasks should be used.
    /// When working in background all requests are handled by `URLSessionDownloadTask`s,
    /// otherwise `URLSessionDataTask` will be used.
    private var isBackground: Bool {
        return manager.session.configuration.networkServiceType == .background
    }

    private var defaultHeaders: [String : String]? {
        return configuration.headers
    }

    public required init(configuration: AnyNetworkServiceConfiguration) {
        manager = Alamofire.SessionManager(configuration: configuration.sessionConfiguration)
        manager.startRequestsImmediately = false
        self.configuration = configuration
    }

    public func builder(for request: AnyRequestable) -> AnyRequestCallBuilder {
        return AlamofireRequestCallBuilder(request: request)
    }

    public func request(_ requestCalls: [AnyRequestCall],
                        option: ExecutionOption,
                        queue: DispatchQueue = .global(),
                        completion: RequestCompletion? = nil) {
        let calls = requestCalls.map(supportedCall)
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
            requests.forEach {
                group?.enter()
                $0.onReady {
                    $0.resume()
                }.onFail { error in
                    group?.leave()
                    if !ignoreFailures,
                       case .success = capturedResult {
                        requests.forEach { $0.request?.cancel() }
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
            let message = "'\(AlamofireNetworkService.self)' does not support '\(type(of: call))'. You should use '\(AlamofireRequestCall.self)'."
            log?.severe(message)
            preconditionFailure(message)
        }
        return supportedCall
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
        let encoding = call.request.encoding.alamofireEncoding
        let headers = constructHeaders(withRequest: call.request)
        let url = constructUrl(withRequest: call.request)

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
                                   self?.appendProgress(request, queue: call.queue) { progress in
                                       call.progress.forEach { $0(progress) }
                                   }.appendResponse(request, call: call, completion: completion)
                                   wrapper.request = request
                               case .failure(let error):
                                wrapper.error = .init(request: request,
                                                      response: nil,
                                                      error: error,
                                                      reason: .encodingFailure,
                                                      body: nil)
                               }
                           })
            return wrapper
        } else if isBackground {
            let destination: DownloadRequest.DownloadFileDestination = { [weak self] tempFileURL, _ in
                func temporaryDirectory() -> URL {
                    if #available(iOS 10.0, *) {
                        return FileManager.default.temporaryDirectory
                    } else {
                        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    }
                }
                
                let defaultFileUrl = temporaryDirectory().appendingPathComponent(tempFileURL.lastPathComponent)
                let defaultOptions: DownloadRequest.DownloadOptions = [.removePreviousFile, .createIntermediateDirectories]
                guard let self = self else { return (defaultFileUrl, defaultOptions) }
                
                let fileUrl = self.configuration.sessionTemporaryFilesDirectory?.appendingPathComponent(tempFileURL.lastPathComponent) ?? defaultFileUrl
                return (fileUrl, defaultOptions)
            }
            let request = manager.download(url,
                                           method: method,
                                           parameters: call.request.parameters,
                                           encoding: encoding,
                                           headers: headers,
                                           to: destination)
            appendProgress(request, queue: call.queue) { progress in
                call.progress.forEach { $0(progress) }
            }.appendResponse(request, call: call, completion: completion)
            return RequestWrapper(request)
        } else {
            let request = manager.request(url,
                                          method: method,
                                          parameters: call.request.parameters,
                                          encoding: encoding,
                                          headers: headers)
            appendProgress(request, queue: call.queue) { progress in
                call.progress.forEach { $0(progress) }
            }.appendResponse(request, call: call, completion: completion)
            return RequestWrapper(request)
        }
    }
}

// MARK: - Constructing request properties.
private extension AlamofireNetworkService {

    func constructUrl(withRequest request: AnyRequestable) -> URL {
        guard let url = URL(string: (request.host ?? configuration.host)) else {
            let message = "Neither default `host` nor request's `host` had been specified."
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
        if let completion = progressCompletion {
            aRequest.downloadProgress(queue: queue) { (progress) in
                completion(progress)
            }
        }
        return self
    }

    @discardableResult
    func appendProgress(_ aRequest: Alamofire.DataRequest,
                        queue: DispatchQueue,
                        progressCompletion: RequestProgressCompletion? = nil) -> Self {
        aRequest.downloadProgress(queue: queue) { (progress) in
            progressCompletion?(progress)
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
        
        let handlingGroup = DispatchGroup()
        (0..<4).forEach { _ in handlingGroup.enter() } // enter group for each scheduled response.
        handlingGroup.notify(queue: call.queue) {
            completion(result)
        }
        aRequest.validate(statusCode: call.request.statusCodes)
         .responseData(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .data,
                                             call: call)
            setResult(result)
            handlingGroup.leave()
        }.responseJSON(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .json,
                                             call: call)
            setResult(result)
            handlingGroup.leave()
        }.responseString(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .string,
                                             call: call)
            setResult(result)
            handlingGroup.leave()
        }.response(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: nil,
                                             kind: .empty,
                                             call: call)
            setResult(result)
            handlingGroup.leave()
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
        
        let handlingGroup = DispatchGroup()
        (0..<4).forEach { _ in handlingGroup.enter() } // enter group for each scheduled response.
        handlingGroup.notify(queue: call.queue) {
            completion(result)
        }
        aRequest.validate(statusCode: call.request.statusCodes)
        .responseData(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .data,
                                             call: call)
            try? $0.destinationURL ==>? FileManager.default.removeItem(at:)
            setResult(result)
            handlingGroup.leave()
        }.responseJSON(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .json,
                                             call: call)
            try? $0.destinationURL ==>? FileManager.default.removeItem(at:)
            setResult(result)
            handlingGroup.leave()
        }.responseString(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: $0.value,
                                             kind: .string,
                                             call: call)
            try? $0.destinationURL ==>? FileManager.default.removeItem(at:)
            setResult(result)
            handlingGroup.leave()
        }.response(queue: call.queue) { [weak self] in
            guard let self = self else { return }
            let result = self.handleResponse($0.response,
                                             error: $0.error,
                                             value: nil,
                                             kind: .empty,
                                             call: call)
            try? $0.destinationURL ==>? FileManager.default.removeItem(at:)
            setResult(result)
            handlingGroup.leave()
        }
        return self
    }

    private func handleResponse(_ response: HTTPURLResponse?,
                                error: Error?,
                                value: Any?,
                                kind: ResponseKind,
                                call: AlamofireRequestCall) -> EmptyResponse {
        guard let httpResponse = response else {
            log?.severe("HTTP Response was not specified. Response will be ignored.")
            call.errorHandler?.handle(request: call.request,
                                      response: nil,
                                      error: error,
                                      reason: .unreachable,
                                      body: nil)
        
            return .failure(.init(request: call.request,
                                  response: nil,
                                  error: error,
                                  reason: .unreachable,
                                  body: nil))
        }
        
        let shouldProcess = self.interceptors?.allSatisfy { $0.intercept(call: call, response: httpResponse, body: value) } ?? true
        
        // If any interceptor blocked response processing then exit.
        guard shouldProcess else {
            log?.warning("At least one interceptor has blocked response for \(call.request).")
           
            call.errorHandler?.handle(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      reason: .skipped,
                                      body: value)
            
            return .failure(.init(request: call.request,
                                  response: httpResponse,
                                  error: error,
                                  reason: .skipped,
                                  body: value))
        }
        
        let status = httpResponse.statusCode
        let validHandlers = call.handlers.filter { $0.statuses.contains(status) && $0.responseType.kind == kind }
        
        // If no handlers attached for given status code with matching kind, produce an error
        guard !validHandlers.isEmpty else {
            
            // If error was received then return generic `.httpError` result
            // Otherwise silently succeed the call as no one is interested in processing result
            guard let error = error else {
                return .success(())
            }
            
            call.errorHandler?.handle(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      reason: .httpError,
                                      body: value)
            return .failure(.init(request: call.request,
                                  response: httpResponse,
                                  error: error,
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
                    log?.error("Failed to construct response of type '\(responseHandler.responseType)' using body: \(value ?? "no body").")
                    call.errorHandler?.handle(request: call.request,
                                              response: httpResponse,
                                              error: constructionError,
                                              reason: .deserializationFailure,
                                              body: value)
                    return .failure(.init(request: call.request,
                                          response: httpResponse,
                                          error: constructionError,
                                          reason: .deserializationFailure,
                                          body: value))
                }
                continue
            }
            
            // If an error was received and it is a validation error
            // we need to deliver Response object to any halders subscribed to status code.
            if let error = error as? AFError,
                error.isResponseValidationError {
                do {
                    let response = try responseHandler.responseType.init(response: httpResponse, body: value)
                    responseHandler.handler(response)
                } catch let constructionError {
                    log?.error("Failed to construct response of type '\(responseHandler.responseType)' using body: \(value ?? "no body").")
                    call.errorHandler?.handle(request: call.request,
                                              response: httpResponse,
                                              error: constructionError,
                                              reason: .deserializationFailure,
                                              body: value)
                    return .failure(.init(request: call.request,
                                          response: httpResponse,
                                          error: error,
                                          reason: .deserializationFailure,
                                          body: value))
                }
            } else {
                // If it is any other error then report the error.
                call.errorHandler?.handle(request: call.request,
                                          response: httpResponse,
                                          error: error,
                                          reason: .httpError,
                                          body: value)
                return .failure(.init(request: call.request,
                                      response: httpResponse,
                                      error: error,
                                      reason: .httpError,
                                      body: value))
            }
        }
        
        // By the end of the loop report successful handling.
        return .success(())
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
        }
    }
}

private extension TSKit_Networking.ParameterEncoding {

    var alamofireEncoding: Alamofire.ParameterEncoding {
        switch self {
        case .json: return JSONEncoding.default
        case .url: return URLEncoding.default
        case .formData: return URLEncoding.default
        case .path: return PathEncoding()
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
