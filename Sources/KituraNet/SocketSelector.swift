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

    private var waitingSockets = Dictionary<Int32, (Socket, NSTimeInterval, (Socket) -> Void)>()

    init() {
        selectorQueue.queueAsync() {[unowned self] in
            self.backgroundSelector()
        }
    }

    func add(socket: Socket, timeout: NSTimeInterval, callback: (Socket) -> Void) {
        updateQueue.queueAsync() {[unowned self] in
            self.waitingSockets[socket.socketfd] = (socket, timeout+NSDate().timeIntervalSinceReferenceDate, callback)
        }
    }

    private func backgroundSelector() {
        var okToRun = true
        var sockets = [Socket]()
        var readySockets: [Socket]?

        while okToRun {
            sockets = []
            
            updateQueue.queueSync() {[unowned self] in

                self.processReadySockets(readySockets)

                let timeNow = NSDate().timeIntervalSinceReferenceDate
            
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
                readySockets = try Socket.wait(for: sockets, timeout: 50)
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
        guard let readySockets = readySockets  else { return }

        for  socket in readySockets {
            if  let info = waitingSockets[socket.socketfd] {
                let (_, _, callback) = info
                callback(socket)
                waitingSockets.removeValue(forKey: socket.socketfd)
            }
        }
    }
}
