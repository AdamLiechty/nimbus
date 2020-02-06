//
// Copyright (c) 2019, Salesforce.com, inc.
// All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
// For full license text, see the LICENSE file in the repo root or https://opensource.org/licenses/BSD-3-Clause
//

import WebKit

public enum JavascriptError: Error {
    case functionNotFound
}

/**
 A `Connection` links a web view to native functions.

 Each connection can bind multiple functions and expose them under
 a single namespace in JavaScript.
 */
public class Connection<C>: Binder {
    public typealias Target = C

    /**
     Create a connection from the web view to an object.
     */
    init(from webView: WKWebView, to target: C, as namespace: String) {
        self.webView = webView
        self.target = target
        self.namespace = namespace
        let messageHandler = ConnectionMessageHandler(connection: self)
        webView.configuration.userContentController.add(messageHandler, name: namespace)
    }

    /**
     Non-generic inner class that can be set as a WKScriptMessageHandler (requires @objc).

     The `WKUserContentController` will retain the message handler, and the message
     handler will in turn retain the `Connection`.
     */
    private class ConnectionMessageHandler: NSObject, WKScriptMessageHandler {
        init(connection: Connection) {
            self.connection = connection
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let params = message.body as? NSDictionary,
                let promiseId = params["promiseId"] as? String else { return }

            let err = unwrapNSNull(params["err"])
            let result = unwrapNSNull(params["result"])
            if err != nil || result != nil {
                handlePromiseCompletion(for: promiseId, err: err as? Error, result: result)
            } else {
                // JS-initiated call into native extension.
                guard let method = params["method"] as? String,
                    let args = params["args"] as? [Any] else { return }

                connection.call(method, args: args, promise: promiseId)
            }
        }

        func handlePromiseCompletion(for promiseId: String, err: Error?, result: Any?) {
            connection.concurrentPromisesQueue.async(flags: .barrier) { [weak self] in
                guard let connection = self?.connection else { return } // Ensure connection is still alive.
                if let completion = connection.promises.removeValue(forKey: promiseId) {
                    // A completion block is already tracked for this Promise. Call that completion.
                    let promiseError = err == nil ? nil : PromiseError.message("\(err!)")
                    completion.call(err: promiseError, result: result)
                } else {
                    // The Promise completion is not yet tracked.; there is no guarantee about whether the
                    // Promise will complete after it is tracked. In this case, store a marker of a completed
                    // Promise, and call the Promise completion handler immediately in the callJavascript
                    // completion in invoke().
                    connection.promises[promiseId] = CompletedPromise(err: err, result: result)
                    return
                }
            }
        }

        let connection: Connection
    }

    /**
     Invokes a Promise-returning Javascript function and call the specified promiseCompletion when that Promise resolves or rejects.
     */
    public func invoke<R>(_ functionName: String, with args: Encodable..., promiseCompletion: @escaping (Error?, R?) -> Void) {
        webView?.callJavascript(name: "nimbus.callAwaiting", args: [namespace, functionName] + args) { (promiseId, err) -> Void in
            if err != nil {
                promiseCompletion(err, nil)
            } else {
                guard let promiseId = promiseId as? String else {
                    promiseCompletion(JavascriptError.functionNotFound, nil)
                    return
                }
                self.concurrentPromisesQueue.async(flags: .barrier) { [weak self] in
                    if let resolvedPromise = self?.promises.removeValue(forKey: promiseId) {
                        // The Promise is already resolved (no ordering guarantees), so just call the completion.
                        promiseCompletion(resolvedPromise.err, resolvedPromise.result as? R)
                    } else {
                        // The Promise is not yet resolved/rejected. Track it until it completes.
                        self?.promises[promiseId] = CallablePromiseCompletion(promiseCompletion)
                    }
                }
            }
        }
    }

    /**
     Bind the callable object to a function `name` under this conenctions namespace.
     */
    public func bind(_ callable: Callable, as name: String) {
        bindings[name] = callable
        let stubScript = """
        \(namespace) = window.\(namespace) || {};
        \(namespace).\(name) = function() {
            let functionArgs = nimbus.cloneArguments(arguments);
            return new Promise(function(resolve, reject) {
                var promiseId = nimbus.uuidv4();
                nimbus.promises[promiseId] = {resolve, reject};

                window.webkit.messageHandlers.\(namespace).postMessage({
                    method: '\(name)',
                    args: functionArgs,
                    promiseId: promiseId
                });
            });
        };
        true;
        """

        let script = WKUserScript(source: stubScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView?.configuration.userContentController.addUserScript(script)
    }

    /**
     Called by the ConnectionMessageHandler when JS in the webview invokes a function of a native extension..
     */
    func call(_ method: String, args: [Any], promise: String) {
        if let callable = bindings[method] {
            do {
                // walk args, converting callbacks into Callables
                let args = args.map { arg -> Any in
                    switch arg {
                    case let dict as NSDictionary:
                        if let callbackId = dict["callbackId"] as? String {
                            return Callback(webView: webView!, callbackId: callbackId)
                        } else {
                            print("non-callback dictionary")
                        }
                    default:
                        break
                    }
                    return arg
                }

                // The `callable` here is the generated Callable* struct instantiated when bind() was called.
                // `args` can be both regular params or `Callback`s which are themselves `Callable`s
                let rawResult = try callable.call(args: args)
                if rawResult is NSArray || rawResult is NSDictionary {
                    resolvePromise(promiseId: promise, result: rawResult)
                } else {
                    var result: EncodableValue
                    if type(of: rawResult) == Void.self {
                        result = .void
                    } else if let encodable = rawResult as? Encodable {
                        result = .value(encodable)
                    } else {
                        throw ParameterError.conversion
                    }
                    resolvePromise(promiseId: promise, result: result)
                }
            } catch {
                rejectPromise(promiseId: promise, error: error)
            }
        }
    }

    private func resolvePromise(promiseId: String, result: Any) {
        var resultString = ""
        if result is NSArray || result is NSDictionary {
            // swiftlint:disable:next force_try
            let data = try! JSONSerialization.data(withJSONObject: result, options: [])
            resultString = String(data: data, encoding: String.Encoding.utf8)!
            webView?.evaluateJavaScript("nimbus.resolvePromise('\(promiseId)', \(resultString));")
        } else {
            switch result {
            case is ():
                resultString = "undefined"
            case let value as EncodableValue:
                // swiftlint:disable:next force_try
                resultString = try! String(data: JSONEncoder().encode(value), encoding: .utf8)!
            default:
                fatalError("Unsupported return type \(type(of: result))")
            }
            webView?.evaluateJavaScript("nimbus.resolvePromise('\(promiseId)', \(resultString).v);")
        }
    }

    private func rejectPromise(promiseId: String, error: Error) {
        webView?.evaluateJavaScript("nimbus.resolvePromise('\(promiseId)', undefined, '\(error)');")
    }

    private static func unwrapNSNull(_ opt: Any?) -> Any? {
        if opt as? NSNull != nil { return nil }
        return opt
    }

    public let target: C
    private let namespace: String
    private weak var webView: WKWebView?
    private var bindings: [String: Callable] = [:]
    private var promises: [String: PromiseCompletion] = [:]
    private let concurrentPromisesQueue = DispatchQueue(label: "Nimbus.promisesQueue", attributes: .concurrent)
}

enum PromiseError: Error, Equatable {
    case message(_ message: String)
}

protocol PromiseCompletion {
    func call(err: Error?, result: Any?)
    var err: Error? { get }
    var result: Any? { get }
}

struct CallablePromiseCompletion<R>: PromiseCompletion {
    typealias FunctionType = (Error?, R?) -> Void
    let function: FunctionType
    init(_ function: @escaping FunctionType) {
        self.function = function
    }

    func call(err: Error?, result: Any?) {
        function(err, result as? R)
    }

    // Unresolved Promises do not yet have errors/results
    var err: Error? { return nil }
    var result: Any? { return nil }
}

struct CompletedPromise: PromiseCompletion {
    let err: Error?
    let result: Any?
    init(err: Error?, result: Any?) {
        self.err = err
        self.result = result
    }

    func call(err: Error?, result: Any?) {
        // Resolved Promeses already have errors/results
    }
}
