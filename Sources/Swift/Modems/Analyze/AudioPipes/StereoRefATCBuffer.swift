//
//  StereoRefATCBuffer.swift
//  cocoaModem
//
//  Created by Kok Chen on 2/25/05.
//  Swift port of StereoRefATCBuffer.{h,m}.
//
//  A CMTappedPipe which takes imported data and exports instead to the next
//  stage's -importClockData: (MultiStereoATC).
//

import Foundation

@objc(StereoRefATCBuffer)
class StereoRefATCBuffer: CMTappedPipe {

    @objc(importData:)
    override func importData(_ pipe: CMPipe!) {
        data.pointee = pipe.stream().pointee
        if let outputClient = outputClient {
            outputClient.perform(Selector(("importClockData:")), with: self)
        }
    }
}
