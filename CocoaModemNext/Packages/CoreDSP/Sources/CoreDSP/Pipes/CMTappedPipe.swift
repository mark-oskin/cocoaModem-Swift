//
//  CMTappedPipe.swift
//   Filter (CoreModem)
//
//  Created by Kok Chen on 10/30/05.
//  Swift port of CMTappedPipe.{h,m}.  Adds a secondary "tap" client (used for
//  scope taps) to CMPipe.
//
//  Coordination note: `tapClient : CMPipe?` is module-visible (subclasses
//  converted by other agents reference it by name, e.g. CMATCBuffer).
//

import Foundation

class CMTappedPipe: CMPipe {

    internal var tapClient: CMPipe?

    override init() {
        super.init()
        tapClient = nil
    }

    //  Returns the secondary CMPipe object which this CMPipe sends data to
    func tap() -> CMPipe? {
        return tapClient
    }

    //  Sets the secondary CMPipe client, if any (usually used for scope taps)
    func setTap(_ tap: CMPipe?) {
        tapClient = tap
    }

    //  call client's importData method with our data, then the tap
    override func exportData() {
        super.exportData()
        if let tapClient = tapClient {
            tapClient.importData(self)
        }
    }
}
