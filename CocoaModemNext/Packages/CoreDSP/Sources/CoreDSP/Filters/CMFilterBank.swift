//
//  CMFilterBank.swift
//  CoreModem
//
//  Created by Kok Chen on 10/25/05.
//  Swift port of CMFilterBank.{h,m}.  A CMTappedPipe holding up to 32 filters;
//  input is routed to the selected filter, whose output is fed back through
//  -importPipelinedData:.
//
//  The `filters` ivar collides with the -filters accessor selector, so the
//  stored count is `filtersCount`.
//

import Foundation

class CMFilterBank: CMTappedPipe {

    internal var filter = [CMPipe?](repeating: nil, count: 32)
    internal var selectedFilter: CMPipe?
    internal var filtersCount: Int32

    override init() {
        filtersCount = 0
        super.init()
        filtersCount = 0
        selectedFilter = nil
    }

    func filters() -> Int32 {
        return filtersCount
    }

    func selectFilter(_ index: Int32) {
        if index >= filtersCount { return }
        selectedFilter = filter[Int(index)]
    }

    func installFilter(_ f: CMPipe?) {
        if filtersCount == 0 { selectedFilter = f }
        if filtersCount > 31 { return }

        filter[Int(filtersCount)] = f
        filtersCount += 1
        //  send filter output to our pipelined buffer
        f?.setPipelinedClient(self)
    }

    //  input is sent here and routed to the selected filter
    override func importData(_ pipe: CMPipe!) {
        //  send input to the selected filter
        if let selectedFilter = selectedFilter { selectedFilter.importData(pipe) }
    }
}
