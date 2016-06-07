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
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

import LoggerAPI
import KituraSys
import CSelectUtilities

import Socket

class SocketSelector {
    private let selectTimeout = 50  // In milliseconds
    
    private let selectorQueue = Queue(type: .serial, label: "SocketSelector")

    private var waitingSockets = [SocketSelectorData]()

    private var maximumEverFileDescriptor = 0

    init() {
        let fileDescriptorSetSize = getFileDescriptorSetSize()
        for _ in 0 ..< fileDescriptorSetSize {
            waitingSockets.append(SocketSelectorData())
        }
        selectorQueue.enqueueAsynchronously() {[unowned self] in
            self.backgroundSelector()
        }
    }
    
    func add(socket: Socket) {
        let fileDescriptor = Int(socket.socketfd)
        if  fileDescriptor > 0 {
            waitingSockets[fileDescriptor].socket = socket

            if  fileDescriptor > maximumEverFileDescriptor  {
                maximumEverFileDescriptor = fileDescriptor
            }
        }
    }

    func wait(socket: Socket, timeout: NSTimeInterval, callback: (Socket) -> Void) {
        let fileDescriptor = socket.socketfd
        if  fileDescriptor > 0  {
            let info = self.waitingSockets[Int(fileDescriptor)]
            info.timeout = timeout
            info.callback = callback
        }
    }
    
    func remove(fileDescriptor: Int32) {
	    if  fileDescriptor > 0  {
            waitingSockets[Int(fileDescriptor)].socket = nil
	    }
    }

    private func backgroundSelector() {
        var okToRun = true
        var fileDescriptorSet = fd_set()

        while okToRun {
            
            // Setup the timeout...
            var timer = timeval()
            
            #if os(Linux)
                timer.tv_usec = Int(selectTimeout * 1000)
            #else
                timer.tv_usec = Int32(selectTimeout * 1000)
            #endif
            
            var maximumFileDescriptor: Int32 = 0
            zeroFileDescriptorSet(&fileDescriptorSet)
            
            for index in 0 ... maximumEverFileDescriptor  {
                let info = waitingSockets[index]
                if  info.socket != nil  &&  info.socket != nil  {
                    maximumFileDescriptor = Int32(index)
                    setFileDescriptorBit(maximumFileDescriptor, &fileDescriptorSet)
                }
            }
            
            let count = select(maximumFileDescriptor+1, &fileDescriptorSet, nil, nil, &timer)
            
            if  count < 0  &&  errno != EBADF  {
                Log.error(String(validatingUTF8: strerror(errno)) ?? "Error: \(errno)")
                print(String(validatingUTF8: strerror(errno)) ?? "Error: \(errno)")
		        print("Errno=\(errno)")
                okToRun = false
            }
            else if  count > 0 {
                // Some file descriptors are ready to be read from
                processReadySockets(count: Int(count), maximumFileDescriptor: maximumFileDescriptor, fileDescriptorSet: &fileDescriptorSet)
            }
            else {  // Either the select timed out or we received an error of a Bad File descriptor, which we ignore....
                removeTimedoutSockets(maximumFileDescriptor: maximumFileDescriptor)
            }
        }
    }
    
    private func processReadySockets(count: Int, maximumFileDescriptor: Int32, fileDescriptorSet: inout fd_set) {
        var localMaximumFileDescriptor = maximumFileDescriptor
        var localCount = count
        while localCount > 0  &&  localMaximumFileDescriptor > 0  {
            if  isFileDescriptorBitSet(localMaximumFileDescriptor, &fileDescriptorSet) == 1  {
                localCount -= 1
                let info = waitingSockets[Int(localMaximumFileDescriptor)]
                if  let callback = info.callback,
                      let socket = info.socket  {
                    callback(socket)
                }
                info.callback = nil
            }
            localMaximumFileDescriptor -= 1
        }
        
        removeTimedoutSockets(maximumFileDescriptor: maximumFileDescriptor)
    }
    
    private func removeTimedoutSockets(maximumFileDescriptor: Int32) {
        let timeNow = NSDate().timeIntervalSinceReferenceDate

        for  index in 0 ..< Int(maximumFileDescriptor)  {
            let info = self.waitingSockets[index]
            if  let socket = info.socket  where  info.timeout < timeNow  {
                socket.close()
                info.socket = nil
                info.callback = nil
            }
        }
    }
    
    private class SocketSelectorData {
        private var socket: Socket?
        private var timeout: NSTimeInterval = 0.0
        private var callback: ((Socket) -> Void)?
    }
    
}
