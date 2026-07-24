//
//  CWMacros.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 1/10/07.
//  Swift port of CWMacros.m.
//

import Cocoa

//  Plist keys (must match Plist.h byte-for-byte).
private let kWBCWMessages = "WBCW Messages"
private let kWBCWMessageTitles = "WBCW MessageTitles"
private let kWBCWOptMessages = "WBCW Option Messages"
private let kWBCWOptMessageTitles = "WBCW Option MessageTitles"
private let kWBCWShiftMessages = "WBCW Shift Messages"
private let kWBCWShiftMessageTitles = "WBCW Shift MessageTitles"

/* local (were global C functions, used only in this file) */
private func cwMessageKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kWBCWOptMessages
	case 2:  return kWBCWShiftMessages
	default: return kWBCWMessages
	}
}

private func cwTitleKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kWBCWOptMessageTitles
	case 2:  return kWBCWShiftMessageTitles
	default: return kWBCWMessageTitles
	}
}

@objc(CWMacros)
class CWMacros: MacroSheet {

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
			appendToMessageBuf( String( UnicodeScalar( UInt8( 6 ) ) ) )	// ^F
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
		pref.setString( "", forKey: cwMessageKey( index ) )
		pref.setString( "", forKey: cwTitleKey( index ) )
	}

	//  update all macros from the plist (called after fetchPlist )
	@objc(updateFromPlist:option:)
	@discardableResult
	func updateFromPlist( _ pref: Preferences, option index: Int32 ) -> Bool {
		updateFromPlist( pref, messageKey: cwMessageKey( index ), titleKey: cwTitleKey( index ) )
		return true
	}

	//  fetch all macros to save to the plist (called befoire savePlist )
	@objc(retrieveForPlist:option:)
	func retrieveForPlist( _ pref: Preferences, option index: Int32 ) {
		retrieveForPlist( pref, messageKey: cwMessageKey( index ), titleKey: cwTitleKey( index ) )
	}
}
