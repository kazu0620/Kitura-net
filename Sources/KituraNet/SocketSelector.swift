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

import Foundation

import LoggerAPI
import KituraSys

import Socket

class SocketSelector {
    private let updateQueue = Queue(type: .serial, label: "SocketSelectorUpdate")
    private let selectorQueue = Queue(type: .serial, label: "SocketSelector")
    private var fakeSocket: Socket?
    private let pipe = NSPipe()
    private let outputBuffer: [UInt8] = [0x88]
    private var inputBuffer: [UInt8] = [0x00]

    private var waitingSockets = Dictionary<Int32, (Socket, NSTimeInterval, (Socket) -> Void)>()

    init() {
        let remoteAddress = createFakeRemoteAddress()
        do {
            try fakeSocket = Socket.create(fromNativeHandle: pipe.fileHandleForReading.fileDescriptor, address: remoteAddress)

            selectorQueue.queueAsync() {[unowned self] in
                self.backgroundSelector()
            }
        }
        catch let error as Socket.Error {
            Log.error("Failed to setup SocketSelector. Error=\(error.description)")
        } catch {
            Log.error("Unexpected error...")
        }
    }

    func add(socket: Socket, timeout: NSTimeInterval, callback: (Socket) -> Void) {
        updateQueue.queueSync() {[unowned self] in
            self.waitingSockets[socket.socketfd] = (socket, timeout+NSDate().timeIntervalSinceReferenceDate, callback)
            self.pingBackgroundSelector()
        }
    }

    private func backgroundSelector() {
        guard let fakeSocket = fakeSocket else {
            return
        }

        var okToRun = true
        var sockets = [Socket]()
        var readySockets: [Socket]?

        while okToRun {
            sockets = []
            
            updateQueue.queueSync() {[unowned self] in

                self.processReadySockets(readySockets)

                let timeNow = NSDate().timeIntervalSinceReferenceDate
            
                sockets.append(fakeSocket)
                for (fileDescriptor, info) in self.waitingSockets {
                    let (socket, timeout, _) = info
                    if  timeout < timeNow  {
                        socket.close()
                        self.waitingSockets.removeValue(forKey: fileDescriptor)
                    }
                    else {
                        sockets.append(socket)
                    }
                }
            }

            do {
                readySockets = try Socket.wait(for: sockets, timeout: 10000)
            }
            catch let error as Socket.Error {
                Log.error("Failed to setup SocketSelector. Error=\(error.description)")
                okToRun = false
            } catch {
                Log.error("Unexpected error...")
                okToRun = false
            }
        }
    }

    private func processReadySockets(_ readySockets: [Socket]?) {
        guard let readySockets = readySockets,
                    let fakeSocket = fakeSocket  else { return }

        for  socket in readySockets {
            if socket.socketfd == fakeSocket.socketfd {
                read(pipe.fileHandleForReading.fileDescriptor, UnsafeMutablePointer<UInt8>(inputBuffer), 1)
            }
            else {
                if  let info = waitingSockets[socket.socketfd] {
                    let (_, _, callback) = info
                    callback(socket)
                    waitingSockets.removeValue(forKey: socket.socketfd)
                }
            }
        }
    }

    private func pingBackgroundSelector() {
        write(pipe.fileHandleForWriting.fileDescriptor, UnsafeMutablePointer<UInt8>(outputBuffer), 1)
    }

    private func createFakeRemoteAddress() -> Socket.Address {
        var socketAddress: sockaddr_in = sockaddr_in()
        memset(&socketAddress, 0, sizeof(sockaddr_in))

        #if os(OSX)
            socketAddress.sin_family = UInt8(AF_INET)
            socketAddress.sin_len = UInt8(sizeof(socketAddress.dynamicType))
        #else
            socketAddress.sin_family = UInt16(AF_INET)
        #endif

        socketAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        socketAddress.sin_port = 0

        return Socket.Address.ipv4(socketAddress)
    }
}
