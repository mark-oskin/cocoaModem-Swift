//
//  CMPipe.swift
//   Filter (CoreModem)
//
//  Created by Kok Chen on 10/24/05.
//  Swift port of CMPipe.{h,m}.  CMPipe is the root of the entire CMPipe DSP
//  pipeline tree; every pipe/filter/mixer subclasses it.
//
//  Coordination notes (other agents' subclasses depend on these EXACT names):
//    - outputClient : CMPipe?                         (module-visible)
//    - data         : UnsafeMutablePointer<CMDataStream>!  (module-visible)
//    - isPipelined  : Bool                            (module-visible)
//  The original C ivar `CMDataStream staticStream` (an embedded value) is here
//  a heap allocation so that `data` (and the pointer returned by -stream) has a
//  stable address exactly as `data = &staticStream` did in C.  It is freed in
//  deinit (ARC does not manage the malloc'd storage).
//

import Foundation

@objc(CMPipe)
class CMPipe: NSObject {

    internal var outputClient: CMPipe?
    //  backing storage for the pipe's own data stream (was `CMDataStream staticStream`)
    internal var staticStream: UnsafeMutablePointer<CMDataStream>
    internal var data: UnsafeMutablePointer<CMDataStream>!
    internal var isPipelined: Bool

    override init() {
        staticStream = UnsafeMutablePointer<CMDataStream>.allocate(capacity: 1)
        staticStream.initialize(to: CMDataStream())
        isPipelined = false
        super.init()
        outputClient = nil
        isPipelined = false
        data = staticStream                //  v0.80l  (was `data = &staticStream`)
        data.pointee.array = nil
        data.pointee.userData = 0
        data.pointee.samples = 0
        data.pointee.components = 0
        data.pointee.channels = 1
    }

    deinit {
        staticStream.deallocate()
    }

    //  Initializes the pipe with a CMPipe client.
    //
    //  In the original Objective-C this was called as [[Class alloc] pipeWithClient:c],
    //  where the method itself invoked [self init].  In the whole-Swift module the
    //  callers construct with Class() (alloc+init) and then call pipe(withClient:);
    //  init has therefore already run, so this only installs the client.
    @objc(pipeWithClient:)
    @discardableResult
    func pipe(withClient client: CMPipe?) -> CMPipe? {
        outputClient = client
        return self
    }

    //  Returns the CMPipe object which this CMPipe sends data to
    @objc func client() -> CMPipe? {
        return outputClient
    }

    //  Sets the CMPipe client.
    @objc(setClient:)
    func setClient(_ inClient: CMPipe?) {
        outputClient = inClient
        isPipelined = false
    }

    //  Sets the alternate CMPipe client (output sent to client's -importPipelinedData)
    @objc(setPipelinedClient:)
    func setPipelinedClient(_ inClient: CMPipe?) {
        outputClient = inClient
        isPipelined = true
    }

    //  Returns the storage used for the data stream
    @objc func stream() -> UnsafeMutablePointer<CMDataStream>! {
        return data
    }

    //  base class implements a NOP pipe: forward the data to the next stage
    @objc(importData:)
    func importData(_ pipe: CMPipe!) {
        data.pointee = pipe.stream().pointee
        exportData()
    }

    @objc(importPipelinedData:)
    func importPipelinedData(_ pipe: CMPipe!) {
        data.pointee = pipe.stream().pointee
        exportData()
    }

    //  call client's importData method with our data
    @objc func exportData() {
        if let outputClient = outputClient {
            if isPipelined {
                outputClient.importPipelinedData(self)
            } else {
                outputClient.importData(self)
            }
        }
    }
}
