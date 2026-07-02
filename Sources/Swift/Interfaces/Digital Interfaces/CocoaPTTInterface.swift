//
//  CocoaPTTInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/16/11.
//  Swift port of CocoaPTTInterface.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(CocoaPTTInterface)
class CocoaPTTInterface: DigitalInterface {

	//  DigitalInterfaces.h : kCocoaPTTType
	private static let kCocoaPTTType: Int32 = 1

	private var keyScript: NSAppleScript?
	private var unkeyScript: NSAppleScript?
	private var quitScript: NSAppleScript?

	@objc(initWithName:)
	override init( name vname: String )
	{
		super.init( name: vname )
		interfaceHasPTT = true
		interfaceType = CocoaPTTInterface.kCocoaPTTType

		if NSWorkspace.shared.fullPath( forApplication: "cocoaPTT" ) != nil {
			keyScript = loadScriptFor( "pttKey" )
			unkeyScript = loadScriptFor( "pttUnkey" )
			quitScript = loadScriptFor( "pttQuit" )
		}
	}

	@objc override func connected() -> Bool
	{
		return ( keyScript != nil && unkeyScript != nil )
	}

	@objc override func closeConnection()
	{
		if interfaceConnected {
			if quitScript != nil { quitScript = executeScript( quitScript!, withError: "cocoaPTT" ) }
			interfaceConnected = false
		}
	}

	@objc(setPTTState:)
	override func setPTTState( _ state: Bool )
	{
		//  don't do anything unless both scripts exist
		if keyScript == nil || unkeyScript == nil { return }

		if state {
			keyScript = executeScript( keyScript!, withError: "cocoaPTT" )
			if keyScript != nil { interfaceConnected = true }
		}
		else {
			unkeyScript = executeScript( unkeyScript!, withError: "cocoaPTT" )
			if unkeyScript != nil { interfaceConnected = true }
		}
	}
}
