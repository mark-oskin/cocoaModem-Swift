//
//  Transceiver.swift
//  cocoaModem
//
//  Created by Kok Chen on 9/4/05.
//  Swift port of Transceiver.m.
//

import Cocoa

//  Implements AppleScript "transceiver" class

@objc(Transceiver)
class Transceiver: NSObject {

	//  4-character transceiver-state codes from modemTypes.h:
	//    ModemTransmit = 'trTX'   ModemReceive = 'trRX'
	private static let ModemTransmit: Int32 = 0x74725458		//  'trTX'
	private static let ModemReceive: Int32 = 0x74725258		//  'trRX'

	private var theModem: Modem!
	private var theTransmitter: Module!
	private var theReceiver: Module!
	private var index: Int32 = 0

	@objc(initWithModem:index:)
	init( modem parent: Modem, index inIndex: Int32 )
	{
		super.init()
		index = inIndex
		theModem = parent
		theTransmitter = Module( transceiver: self, receiver: false, index: index )
		theReceiver = Module( transceiver: self, receiver: true, index: index )
	}

	@objc func modem() -> Modem!
	{
		return theModem
	}

	@objc func transmitter() -> Module!
	{
		return theTransmitter
	}

	@objc func receiver() -> Module!
	{
		return theReceiver
	}

	//  deprecated
	@objc func getStream() -> String?
	{
		return theReceiver.stream()
	}

	// deprecated
	@objc(sendStream:)
	func sendStream( _ text: UnsafeMutablePointer<CChar>? )
	{
		theTransmitter.setCStream( text )
	}

	@objc func enable() -> Bool
	{
		return theModem.checkEnable( self )
	}

	@objc(setEnable:)
	func setEnable( _ sense: Bool )
	{
		theModem.setEnable( self, to: sense )
	}

	@objc func state() -> Int32
	{
		return theModem.currentTransmitState() ? Transceiver.ModemTransmit : Transceiver.ModemReceive
	}

	@objc(setState:)
	func setState( _ code: Int32 )
	{
		let transmitState = theModem.currentTransmitState()
		//  check if we are already in the correct states
		if code == Transceiver.ModemTransmit && transmitState { return }
		if code != Transceiver.ModemTransmit && !transmitState { return }
		theModem.select( self, andChangeTransmitStateTo: code == Transceiver.ModemTransmit )
	}

	//  get modulation (4 letter code)
	@objc func modulation() -> Int32
	{
		return theModem.modulationCode( for: self )
	}

	@objc(setModulation:)
	func setModulation( _ code: Int32 )
	{
		theModem.setModulationCodeFor( self, to: code )
	}
}
