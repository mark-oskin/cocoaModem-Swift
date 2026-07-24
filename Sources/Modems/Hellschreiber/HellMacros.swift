//
//  HellMacros.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon Jan 30 2006.
//  Swift port of HellMacros.m.
//

import Cocoa

//  Plist keys (must match Plist.h byte-for-byte).
private let kHellMessages = "Hell Messages"
private let kHellMessageTitles = "Hell MessageTitles"
private let kHellOptMessages = "Hell Option Messages"
private let kHellOptMessageTitles = "Hell Option MessageTitles"
private let kHellShiftMessages = "Hell Shift Messages"
private let kHellShiftMessageTitles = "Hell Shift MessageTitles"

/* local (were global C functions, used only in this file) */
private func hellMessageKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kHellOptMessages
	case 2:  return kHellShiftMessages
	default: return kHellMessages
	}
}

private func hellTitleKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kHellOptMessageTitles
	case 2:  return kHellShiftMessageTitles
	default: return kHellMessageTitles
	}
}

@objc(HellMacros)
class HellMacros: MacroSheet {

	//  button macros
	override func executeButtonMacro( _ str: UnsafeMutablePointer<CChar>?, modem macroInterface: MacroInterface? ) -> Bool {
		guard let str = str else { return false }

		if str[0] == CChar( UInt8( ascii: "r" ) ) && str[1] == CChar( UInt8( ascii: "x" ) ) {
			//  add to end of stream
			excessTransmitMacros -= 1
			appendToMessageBuf( String( UnicodeScalar( UInt8( 5 ) ) ) )	// ^E
			return true
		}
		if str[0] == CChar( UInt8( ascii: "t" ) ) && str[1] == CChar( UInt8( ascii: "x" ) ) {
			//  immediate
			excessTransmitMacros += 1
			macroInterface?.sendMessageImmediately()
			return true
		}
		//  v0.89 MacroScript
		if str[0] == CChar( UInt8( ascii: "a" ) ) {
			return executeMacroScript( str )
		}
		return false
	}

	//  set up defaults before Plist is fetched
	@objc(setupDefaultPreferences:option:)
	func setupDefaultPreferences( _ pref: Preferences, option index: Int32 ) {
		let mNames = [ "Macros", "Option Macros", "Option-Shift Macros" ]

		if nameOutlet != nil { nameOutlet.stringValue = mNames[ Int( index ) ] }
		pref.setString( "", forKey: hellMessageKey( index ) )
		pref.setString( "", forKey: hellTitleKey( index ) )
	}

	//  update all macros from the plist (called after fetchPlist )
	@objc(updateFromPlist:option:)
	@discardableResult
	func updateFromPlist( _ pref: Preferences, option index: Int32 ) -> Bool {
		updateFromPlist( pref, messageKey: hellMessageKey( index ), titleKey: hellTitleKey( index ) )
		return true
	}

	//  fetch all macros to save to the plist (called befoire savePlist )
	@objc(retrieveForPlist:option:)
	func retrieveForPlist( _ pref: Preferences, option index: Int32 ) {
		retrieveForPlist( pref, messageKey: hellMessageKey( index ), titleKey: hellTitleKey( index ) )
	}
}
