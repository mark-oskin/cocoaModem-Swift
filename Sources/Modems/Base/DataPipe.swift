//
//  DataPipe.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/3/08.
//  Copyright 2008 Kok Chen, W7AY. All rights reserved.
//
//  Swift port of DataPipe.m.
//
//  NSPipe is not completely ThreadSafe (it uses autorelease objects that could
//  be released in different threads).  DataPipe attempts to create a simple
//  thread safe data pipeline.
//
//  The malloc'd `char *data` becomes an UnsafeMutablePointer<CChar> that is
//  allocated in init and freed in deinit (ARC does not free C buffers).  The
//  read/write paths mirror the original memcpy() calls and byte-index math
//  exactly (raw-pointer arithmetic advances by bytes, matching the C void*/char*
//  pointer math).
//

import Foundation

//  enum PipeLockCondition { kNoPipeData, kHasPipeData }
private let kNoPipeData = 0
private let kHasPipeData = 1

@objc(DataPipe)
class DataPipe: NSObject {

    private let lock: NSConditionLock
    private let capacity: Int32
    private let data: UnsafeMutablePointer<CChar>
    private var bytes: Int32 = 0
    private var eofFlag: Bool = false
    //  write retry
    private var timeout: Int32 = 200          //  retries (200*.005 = 2 secs)
    private var writeRetryTime: Float = 0.005 //  5 ms

    override convenience init() {
        self.init(capacity: 512 * Int32(MemoryLayout<Float>.size))
    }

    //  Sets up the capacity of the pipe.
    //  Upon a read, the pipe will block if there is insufficient data.
    //  Upon a write, the pipe will wait for enough capacity to write all the
    //  data (or time out after 1 second).
    @objc(initWithCapacity:)
    init(capacity bytesCapacity: Int32) {
        var cap = bytesCapacity
        if cap < 512 { cap = 512 }
        capacity = cap
        data = UnsafeMutablePointer<CChar>.allocate(capacity: Int(cap))
        lock = NSConditionLock(condition: kNoPipeData)
        //  bytes = 0, eof = NO, timeout = 200, writeRetryTime = 0.005 (defaults)
        super.init()
    }

    deinit {
        eofFlag = true
        data.deallocate()
    }

    //  Returns the number of bytes successfully written into the pipe.
    //  If enough capacity is not released within 1 second, the write returns
    //  with a count of bytes it has successfully written.
    @objc(write:length:)
    func write(_ buffer: UnsafeMutableRawPointer, length requestBytes: Int32) -> Int32 {
        var written: Int32 = 0
        var requestBytes = requestBytes
        var buffer = buffer

        //  Loop here waiting (Thread sleep) if needed for a pipe that has
        //  reached capacity to drain.  Give up after "timeout" tries.
        let originalRequest = requestBytes
        for _ in 0..<timeout {
            lock.lock()   //  unconditional lock to write data in
            //  received lock, attempt to write
            let availableForWriting = capacity - bytes
            if availableForWriting < requestBytes {
                //  capacity overflow!
                if availableForWriting > 0 {
                    //  write as much as we can...
                    memcpy(data + Int(bytes), buffer, Int(availableForWriting))
                    requestBytes -= availableForWriting
                    bytes += availableForWriting
                    written += availableForWriting
                    buffer = buffer + Int(availableForWriting)
                }
                //  ... then give the read thread a chance to read
                lock.unlock(withCondition: kHasPipeData)
                //  sleep this thread for 5 ms before resuming trying to write more
                Thread.sleep(forTimeInterval: TimeInterval(writeRetryTime))
            } else {
                memcpy(data + Int(bytes), buffer, Int(requestBytes))
                bytes += requestBytes
                lock.unlock(withCondition: kHasPipeData)
                return originalRequest
            }
        }
        return written
    }

    @objc(eof)
    func eof() -> Bool {
        return eofFlag
    }

    @objc(setEOF)
    func setEOF() {
        eofFlag = true
    }

    //  Returns byte count or -1 if EOF.
    //  Returns 0 if there is no data in the pipeline.
    @objc(readAvailableData:max:)
    func readAvailableData(_ indata: UnsafeMutableRawPointer, max maxBytes: Int32) -> Int32 {
        if eofFlag { return -1 }
        if maxBytes == 0 { return 0 }
        if bytes <= 0 { return 0 }

        lock.lock(whenCondition: kHasPipeData)

        let copied = (bytes > maxBytes) ? maxBytes : bytes
        if copied <= 0 {
            //  some inconsistent error or client error (requesting 0 bytes)
            //  occurred, but assume we have no data available
            lock.unlock(withCondition: kNoPipeData)
            return 0
        }
        memcpy(indata, data, Int(copied))
        bytes -= copied
        if bytes > 0 {
            //  move remaining data to head of data buffer
            memcpy(data, data + Int(copied), Int(bytes))
            lock.unlock(withCondition: kHasPipeData)
            return copied
        }
        lock.unlock(withCondition: kNoPipeData)
        return copied
    }

    @objc(readData:length:)
    func readData(_ buffer: UnsafeMutableRawPointer, length requestBytes: Int32) -> Int32 {
        if eofFlag { return -1 }
        if requestBytes == 0 { return 0 }
        var requestBytes = requestBytes
        if requestBytes > capacity { requestBytes = capacity }
        var buffer = buffer

        let originalRequest = requestBytes
        while true {
            lock.lock(whenCondition: kHasPipeData)
            if bytes < requestBytes {
                if bytes > 0 {
                    memcpy(buffer, data, Int(bytes))
                    requestBytes -= bytes
                    buffer = buffer + Int(bytes)          //  v0.62
                    bytes = 0
                    //  v0.61 bug  buffer += requestBytes ;
                }
                //  wait for more data to be collected before returning request
                lock.unlock(withCondition: kNoPipeData)
            } else {
                memcpy(buffer, data, Int(requestBytes))
                bytes -= requestBytes
                if bytes > 0 {
                    //  move remaining data to head of buffer
                    memcpy(data, data + Int(requestBytes), Int(bytes))
                    lock.unlock(withCondition: kHasPipeData)
                    return originalRequest
                }
                lock.unlock(withCondition: kNoPipeData)
                return originalRequest
            }
        }
    }
}
