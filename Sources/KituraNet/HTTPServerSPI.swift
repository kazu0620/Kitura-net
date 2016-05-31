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

import Socket
import LoggerAPI

// MARK: HTTPServerSPI

class HTTPServerSPI {
    
    /// 
    /// Delegate for handling the HTTPServer connection 
    ///
    weak var delegate: HTTPServerSPIDelegate?
    
    ///
    /// Whether the HTTP service provider handler has stopped runnign
    ///
    var stopped = false

    ///
    /// Handles instructions for listening on a socket
    ///
    /// - Parameter socket: socket to use for connecting 
    /// - Parameter port: number to listen on
    ///
    func spiListen(socket: Socket?, port: Int) {
        
        do {
            guard let socket = socket, let delegate = delegate else {
                return
            }

            try socket.listen(on: port)
            Log.info("Listening on port \(port)")

            // TODO: Change server exit to not rely on error being thrown
            repeat {
                let clientSocket = try socket.acceptClientConnection()
                Log.info("Accepted connection from: " +
                         "\(clientSocket.remoteHostname):\(clientSocket.remotePort)")
                delegate.handleClientRequest(socket: clientSocket)
            } while true
		} catch let error as Socket.Error {
            
            if stopped && error.errorCode == Int32(Socket.SOCKET_ERR_ACCEPT_FAILED) {
                Log.info("Server has stopped listening")
            }
            else {
                Log.error("Error reported:\n \(error.description)")
            }
		} catch {
			Log.error("Unexpected error...")
		}
    }
    
}

///
/// Delegate for a service provider interface
///
protocol HTTPServerSPIDelegate: class {
    
    ///
    /// Handle the client request
    ///
    /// - Parameter socket: the socket
    /// - Parameter fromKeepAlive - Was this from a socket being kept alive
    ///
    func handleClientRequest(socket: Socket)

}
