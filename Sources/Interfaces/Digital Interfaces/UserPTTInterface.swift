//
//  UserPTTInterface.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/11.
//  Swift port of UserPTTInterface.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(UserPTTInterface)
class UserPTTInterface: DigitalInterface {

	//  DigitalInterfaces.h : kUserPTTType
	private static let kUserPTTType: Int32 = 3

	private var keyScript: NSAppleScript?
	private var unkeyScript: NSAppleScript?
	private var quitScript: NSAppleScript?

	@objc(initWithName:)
	override init( name vname: String )
	{
		super.init( name: vname )
		interfaceHasPTT = true
		keyScript = nil
		unkeyScript = nil
		quitScript = nil
		interfaceType = UserPTTInterface.kUserPTTType
	}

	@objc(updateScriptsFromFolder:)
	override func updateScripts( fromFolder newfolder: String ) -> Bool
	{
		scriptFolder = ( newfolder as NSString ).expandingTildeInPath

		keyScript = nil
		unkeyScript = nil
		quitScript = nil

		if scriptFolder.count > 1 {
			keyScript = loadScriptForPath( scriptFolder + "/pttKey.scpt" )
			if keyScript != nil {
				unkeyScript = loadScriptForPath( scriptFolder + "/pttUnkey.scpt" )
				if unkeyScript != nil {
					quitScript = loadScriptForPath( scriptFolder + "/pttQuit.scpt" )
				}
				scriptsLoaded = true
			}
			return true
		}
		else {
			scriptFolder = ""
			scriptsLoaded = false
			return false
		}
	}

	@objc override func connected() -> Bool
	{
		return ( keyScript != nil && unkeyScript != nil )
	}

	@objc override func closeConnection()
	{
		if interfaceConnected {
			if quitScript != nil { quitScript = executeScript( quitScript!, withError: "User Defined PTT Script" ) }
			interfaceConnected = false
		}
	}

	@objc(setPTTState:)
	override func setPTTState( _ state: Bool )
	{
		//  don't do anything unless both scripts exist
		if keyScript == nil || unkeyScript == nil { return }

		if state {
			keyScript = executeScript( keyScript!, withError: "User PTT on" )
			if keyScript != nil { interfaceConnected = true }
		}
		else {
			unkeyScript = executeScript( unkeyScript!, withError: "User PTT off" )
			if unkeyScript != nil { interfaceConnected = true }
		}
	}
}
