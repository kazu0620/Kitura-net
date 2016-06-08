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
    
    weak var delegate: SocketSelectorDelegate?
    
    private let selectTimeout = 50  // In milliseconds
    
    private let selectorQueue = Queue(type: .serial, label: "SocketSelector")

    private var fileDescriptorTimeouts: [NSTimeInterval]

    private var maximumEverFileDescriptor = 0

    init() {
        let fileDescriptorSetSize = Int(getFileDescriptorSetSize())
        fileDescriptorTimeouts = [NSTimeInterval](repeating: 0.0, count: fileDescriptorSetSize)
        
        selectorQueue.enqueueAsynchronously() {[unowned self] in
            self.backgroundSelector()
        }
    }

    func wait(fileDescriptor: Int, timeout: NSTimeInterval) {
        if  fileDescriptor > 0  {
            fileDescriptorTimeouts[fileDescriptor] = timeout
            if  fileDescriptor > maximumEverFileDescriptor  {
                maximumEverFileDescriptor = fileDescriptor
            }
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
                if  fileDescriptorTimeouts[index] > 0.0  {
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
                let fileDescriptor = Int(localMaximumFileDescriptor)
                if  fileDescriptorTimeouts[fileDescriptor] > 0.0  {
                    delegate?.readFrom(fileDescriptor: fileDescriptor)
                    fileDescriptorTimeouts[fileDescriptor] = 0.0
                }
            }
            localMaximumFileDescriptor -= 1
        }
        
        removeTimedoutSockets(maximumFileDescriptor: maximumFileDescriptor)
    }
    
    private func removeTimedoutSockets(maximumFileDescriptor: Int32) {
        let timeNow = NSDate().timeIntervalSinceReferenceDate

        for  index in 0 ..< Int(maximumFileDescriptor)  {
            let timeout = fileDescriptorTimeouts[index]
            if  timeout < timeNow  {
                close(Int32(index))
            }
        }
    }
}
