//
//  MacroScripts.swift
//  cocoaModem 2.0
//
//  Swift port of MacroScripts.m (Kok Chen, 1/20/11).
//  Copyright 2011 Kok Chen, W7AY. All rights reserved.
//

import Cocoa

@objc(MacroScripts)
class MacroScripts: NSObject {
	private var appleScript = [NSAppleScript?]( repeating: nil, count: 6 )

	//	return nil if failed.
	@objc(setScriptFile:index:)
	@discardableResult
	func setScriptFile( _ fileName: String?, index: Int32 ) -> NSAppleScript?
	{
		var dict: NSDictionary?

		appleScript[ Int( index ) ] = nil
		if let fileName = fileName, !fileName.isEmpty {
			let url = URL( fileURLWithPath: ( fileName as NSString ).expandingTildeInPath )
			if let script = NSAppleScript( contentsOf: url, error: &dict ) {
				if script.compileAndReturnError( &dict ) {
					appleScript[ Int( index ) ] = script
					return script
				}
			}
			Messages.appleScriptError( dict as? [AnyHashable: Any], script: "Macro Script" )
		}
		return nil
	}

	@objc(executeMacroScript:)
	func executeMacroScript( _ index: Int32 )
	{
		var dict: NSDictionary?

		if let script = appleScript[ Int( index ) ] {
			script.executeAndReturnError( &dict )
			if dict != nil {
				//  if error, remove AppleScript after a warning message
				Messages.appleScriptError( dict as? [AnyHashable: Any], script: "Macro Script" )
				appleScript[ Int( index ) ] = nil
			}
		}
	}
}
