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

import CSelectUtilities
import KituraSys
import LoggerAPI
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
    private var socketSelector = SocketSelector()
    
    ///
    /// Keep alive timeout in seconds
    ///
    static let keepAliveTimeout: NSTimeInterval = 10
    
    ///
    /// Maximum number of requests handled via keep alive
    ///
    static let maximumKeepAliveRequestCount = 10

    ///
    /// HTTPServerDelegate
    ///
    public weak var delegate: HTTPServerDelegate?
    
    /// 
    /// Port number for listening for new connections
    ///
    public private(set) var port: Int?
    
    /// 
    /// TCP socket used for listening for new connections
    ///
    private var listenSocket: Socket?
    
    ///
    /// Whether the HTTP server has stopped listening
    ///
    var stopped = false
    
    ///
    /// Open sockets
    ///
    var openSockets = [Socket?]()
    
    ///
    /// Number of requests left that can be made on a "socket"
    ///
    var requestsLeft = [Int]()
    
    init() {
        let fileDescriptorSetSize = Int(getFileDescriptorSetSize())
        openSockets = [Socket?](repeating: nil, count: fileDescriptorSetSize)
        requestsLeft = [Int](repeating: 0, count: fileDescriptorSetSize)
        
        socketSelector.delegate = self
    }

    ///
    /// Listens for connections on a socket
    ///
    /// - Parameter port: port number for new connections (ex. 8090)
    /// - Parameter notOnMainQueue: whether to have the listener run on the main queue 
    ///
    public func listen(port: Int, notOnMainQueue: Bool=false) {
        
        self.port = port
		
		do {
            
			self.listenSocket = try Socket.create()
            
		} catch let error as Socket.Error {
			print("Error reported:\n \(error.description)")
		} catch {
            print("Unexpected error...")
		}

		let queuedBlock = {
			self.listen(socket: self.listenSocket, port: self.port!)
		}
		
		if notOnMainQueue {
			HTTPServer.listenerQueue.enqueueAsynchronously(queuedBlock)
		}
		else {
			Queue.enqueueIfFirstOnMain(queue: HTTPServer.listenerQueue, block: queuedBlock)
		}
        
    }

    ///
    /// Stop listening for new connections
    ///
    public func stop() {
        
        if let listenSocket = listenSocket {
            stopped = true
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
    /// Handles instructions for listening on a socket
    ///
    /// - Parameter socket: socket to use for connecting
    /// - Parameter port: number to listen on
    ///
    func listen(socket: Socket?, port: Int) {
        
        do {
            guard let socket = socket else {
                return
            }
            
            try socket.listen(on: port)
            Log.info("Listening on port \(port)")
            
            // TODO: Change server exit to not rely on error being thrown
            repeat {
                let clientSocket = try socket.acceptClientConnection()
                Log.info("Accepted connection from: " +
                    "\(clientSocket.remoteHostname):\(clientSocket.remotePort)")
                handleClientRequest(socket: clientSocket)
            } while true
        } catch let error as Socket.Error {
            
            if stopped && error.errorCode == Int32(Socket.SOCKET_ERR_ACCEPT_FAILED) {
                Log.info("Server has stopped listening")
                print("Server has stopped listening")
            }
            else {
                Log.error("Error reported:\n \(error.description)")
                print("Error reported:\n \(error.description)")
            }
        } catch {
            Log.error("Unexpected error...")
            print("Unexpected error...")
        }
    }
    
    ///
    /// Add a socket to the keep alive handling
    ///
    /// - Parameter keepAliveSocket: The client socket to be kep alive
    ///
    func keepAlive(socket keepAliveSocket: Socket, requestsAllowed: Int) {
        let fileDescriptor = Int(keepAliveSocket.socketfd)
        
//print("about to set requestsLeft[\(fileDescriptor)]")
        requestsLeft[fileDescriptor] = requestsAllowed
//print("set requestsLeft[\(fileDescriptor)]")
        
        let timeout = NSDate().addingTimeInterval(HTTPServer.keepAliveTimeout).timeIntervalSinceReferenceDate
        socketSelector.wait(fileDescriptor: Int(keepAliveSocket.socketfd), timeout: timeout)
    }

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
        
//print("about to set openSockets[\(clientSocket.socketfd)]")
        openSockets[Int(clientSocket.socketfd)] = clientSocket
//print("set openSockets[\(clientSocket.socketfd)]")
        print("handleClientRequest: new client socket")
        
        clientRequestHandler(socket: clientSocket, fromKeepAlive: false, requestsAllowed: HTTPServer.maximumKeepAliveRequestCount)
    }

    
    private func clientRequestHandler(socket clientSocket: Socket, fromKeepAlive: Bool, requestsAllowed: Int) {
        
        guard let delegate = delegate else {
            return
        }
        
        HTTPServer.clientHandlerQueue.enqueueAsynchronously() { [unowned self] in
            
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
                    print("No data")
                    clientSocket.close()
                case .unexpectedEOF:
                    print("Unexpected EOF")
                    clientSocket.close()
                case .internalError:
                    print("Internal error")
                    clientSocket.close()
                }
            }
            
        }
    }
    
}

extension HTTPServer: SocketSelectorDelegate {
    func readFrom(fileDescriptor: Int) {
        guard  fileDescriptor > 0  else { return }
//print("about to reference openSockets[\(fileDescriptor)]")
        guard  let socket = openSockets[fileDescriptor]  where socket.socketfd > 0  else { return }
//print("referenced openSockets[\(fileDescriptor)]")
print("readFrom: about to call handler...")
        clientRequestHandler(socket: socket, fromKeepAlive: true, requestsAllowed: requestsLeft[fileDescriptor])
    }
}


///
/// Delegate protocol for an HTTPServer
///
public protocol HTTPServerDelegate: class {

    func handle(request: ServerRequest, response: ServerResponse)
    
}
