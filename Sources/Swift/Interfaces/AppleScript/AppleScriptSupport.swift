//
//  AppleScriptSupport.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/17/11.
//  Swift port of AppleScriptSupport.m.
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

//  Root of the digital-interface / keyer inheritance tree.  Provides AppleScript
//  loading and execution helpers shared by DigitalInterface and KeyerInterface.

@objc(AppleScriptSupport)
class AppleScriptSupport: NSObject {

	//  base ivars reached by the UserPTTInterface subclass -> internal
	internal var scriptFolder: String = ""
	internal var scriptsLoaded: Bool = false

	override init()
	{
		super.init()
		scriptFolder = ""
		scriptsLoaded = false
	}

	@objc(updateScriptsFromFolder:)
	func updateScripts( fromFolder newfolder: String ) -> Bool
	{
		return false
	}

	@objc func folderName() -> String
	{
		if scriptFolder.count <= 0 { return "" }
		let folderPath = ( scriptFolder as NSString ).pathComponents
		return folderPath[ folderPath.count - 1 ]
	}

	internal func loadScriptForPath( _ path: String, withErrorDictionary dict: inout NSDictionary? ) -> NSAppleScript?
	{
		if path.count > 0 {
			let url = URL( fileURLWithPath: path )
			if !url.isFileURL { return nil }
			guard let script = NSAppleScript( contentsOf: url, error: &dict ) else {
				path.withCString { Messages.appleScriptError( dict as? [AnyHashable: Any], script: $0 ) }
				return nil
			}
			return script
		}
		return nil
	}

	//  load a script file with an arbitrary path name
	internal func loadScriptForPath( _ path: String ) -> NSAppleScript?
	{
		var dict: NSDictionary?
		return loadScriptForPath( path, withErrorDictionary: &dict )
	}

	internal func loadScriptFor( _ scptFile: String, withErrorDictionary dict: inout NSDictionary? ) -> NSAppleScript?
	{
		let path = Bundle.main.path( forResource: scptFile, ofType: "scpt" )
		return loadScriptForPath( path ?? "", withErrorDictionary: &dict )
	}

	//  load a script file from the Application bundle
	internal func loadScriptFor( _ scptFile: String ) -> NSAppleScript?
	{
		var dict: NSDictionary?
		return loadScriptFor( scptFile, withErrorDictionary: &dict )
	}

	//  return the script back if succeeded, return nil if failed
	@discardableResult
	internal func executeScript( _ script: NSAppleScript, withError msg: String ) -> NSAppleScript?
	{
		var err: NSDictionary?
		script.executeAndReturnError( &err )
		if err == nil {
			return script
		}
		// AppleScript error
		msg.withCString { Messages.appleScriptError( err as? [AnyHashable: Any], script: $0 ) }
		return nil
	}

	//  return the script back if succeeded, return nil if failed
	@discardableResult
	internal func executeScript( _ script: NSAppleScript, reply eventDescriptor: inout NSAppleEventDescriptor?, withError msg: String ) -> NSAppleScript?
	{
		var err: NSDictionary?
		eventDescriptor = script.executeAndReturnError( &err )
		if err == nil {
			return script
		}
		// AppleScript error
		msg.withCString { Messages.appleScriptError( err as? [AnyHashable: Any], script: $0 ) }
		return nil
	}
}
