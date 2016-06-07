/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import KituraSys
import Socket

import Foundation

// MARK: HTTPServer

public class HTTPServer {

    ///
    /// Queue for listening and establishing new connections
    ///
    private static var listenerQueue = Queue(type: .parallel, label: "HTTPServer.listenerQueue")

    ///
    /// Queue for handling client requests
    ///
    private static var clientHandlerQueue = Queue(type: .parallel, label: "HTTPServer.clientHandlerQueue")
    
    ///
    /// Maximum number of pending sockets
    ///
    static let maxPendingConnections = 20
    
    ///
    /// Socket select manager
    ///
    private static var socketSelector = SocketSelector()
    
    ///
    /// Keep alive timeout in seconds
    ///
    static let keepAliveTimeout = 10
    
    ///
    /// Keep alive timeout as a NSTimeInterval
    ///
    static let keepAliveTimeoutInterval = NSTimeInterval(keepAliveTimeout)
    
    ///
    /// Maximum number of requests handled via keep alive
    ///
    static let maximumKeepAliveRequestCount = 10

    ///
    /// HTTPServerDelegate
    ///
    public weak var delegate: HTTPServerDelegate?
    
    ///
    /// HTTP service provider interface
    ///
    private let spi: HTTPServerSPI
    
    /// 
    /// Port number for listening for new connections
    ///
    private var _port: Int?
    public var port: Int? {
        get { return _port }
    }
    
    /// 
    /// TCP socket used for listening for new connections
    ///
    private var listenSocket: Socket?
    
    ///
    /// Initializes an HTTPServer instance
    ///
    /// - Returns: an HTTPServer instance
    ///
    public init() {
        
        spi = HTTPServerSPI()
        spi.delegate = self
        
    }

    ///
    /// Listens for connections on a socket
    ///
    /// - Parameter port: port number for new connections (ex. 8090)
    /// - Parameter notOnMainQueue: whether to have the listener run on the main queue 
    ///
    public func listen(port: Int, notOnMainQueue: Bool=false) {
        
        self._port = port
		
		do {
            
			self.listenSocket = try Socket.create()
            
		} catch let error as Socket.Error {
			print("Error reported:\n \(error.description)")
		} catch {
            print("Unexpected error...")
		}

		let queuedBlock = {
			self.spi.spiListen(socket: self.listenSocket, port: self._port!)
		}
		
		if notOnMainQueue {
			HTTPServer.listenerQueue.queueAsync(queuedBlock)
		}
		else {
			Queue.queueIfFirstOnMain(queue: HTTPServer.listenerQueue, block: queuedBlock)
		}
        
    }

    ///
    /// Stop listening for new connections
    ///
    public func stop() {
        
        if let listenSocket = listenSocket {
            spi.stopped = true
            listenSocket.close()
        }
        
    }

    ///
    /// Static method to create a new HTTPServer and have it listen for conenctions
    ///
    /// - Parameter port: port number for accepting new connections
    /// - Parameter delegate: the delegate handler for HTTP connections
    /// - Parameter notOnMainQueue: whether to listen for new connections on the main Queue
    ///
    /// - Returns: a new HTTPServer instance
    ///
    public static func listen(port: Int, delegate: HTTPServerDelegate, notOnMainQueue: Bool=false) -> HTTPServer {
        
        let server = HTTP.createServer()
        server.delegate = delegate
        server.listen(port: port, notOnMainQueue: notOnMainQueue)
        return server
        
    }
    
    ///
    /// Add a socket to the keep alive handling
    ///
    /// - Parameter keepAliveSocket: The client socket to be kep alive
    ///
    func keepAlive(socket keepAliveSocket: Socket, requestsAllowed: Int) {
        HTTPServer.socketSelector.wait(socket: keepAliveSocket, timeout: HTTPServer.keepAliveTimeoutInterval) {[unowned self] (socket: Socket) in
            self.clientRequestHandler(socket: socket, fromKeepAlive: true, requestsAllowed: requestsAllowed)
        }
    }

    ///
    /// Remove a socket from the SocketSelector
    ///
    /// - Parameter socket: The socket to remove
    ///
    func remove(socket: Socket) {
        HTTPServer.socketSelector.remove(fileDescriptor: socket.socketfd)
    }
    
    private func clientRequestHandler(socket clientSocket: Socket, fromKeepAlive: Bool, requestsAllowed: Int) {
        
        guard let delegate = delegate else {
            return
        }
        
        HTTPServer.clientHandlerQueue.queueAsync() {
            
            let request = ServerRequest(socket: clientSocket)
            request.keepAliveRequests = requestsAllowed
            let response = ServerResponse(socket: clientSocket, request: request, server: self)
            request.parse() { status in
                switch status {
                case .success:
                    delegate.handle(request: request, response: response)
                case .parsedLessThanRead:
                    response.statusCode = .badRequest
                    do {
                        try response.end()
                    }
                    catch {
                        // handle error in connection
                    }
                case .noData:
                    HTTPServer.socketSelector.remove(fileDescriptor: clientSocket.socketfd)
                    clientSocket.close()
                case .unexpectedEOF:
                    HTTPServer.socketSelector.remove(fileDescriptor: clientSocket.socketfd)
                    clientSocket.close()
                case .internalError:
                    HTTPServer.socketSelector.remove(fileDescriptor: clientSocket.socketfd)
                    clientSocket.close()
                }
            }
            
        }
    }
    
}

// MARK: HTTPServerSPIDelegate extension
extension HTTPServer : HTTPServerSPIDelegate {

    ///
    /// Handle a new client HTTP request
    ///
    /// - Parameter clientSocket: the socket used for connecting
    ///
    func handleClientRequest(socket clientSocket: Socket) {
        do {
            try clientSocket.setBlocking(mode: true)
        }
        catch { /* Ignore set blocking failure */ }
        
        HTTPServer.socketSelector.add(socket: clientSocket)
        
        clientRequestHandler(socket: clientSocket, fromKeepAlive: false, requestsAllowed: HTTPServer.maximumKeepAliveRequestCount)
        
    }
}

///
/// Delegate protocol for an HTTPServer
///
public protocol HTTPServerDelegate: class {

    func handle(request: ServerRequest, response: ServerResponse)
    
}
