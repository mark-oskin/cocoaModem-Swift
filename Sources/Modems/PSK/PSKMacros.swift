//
//  PSKMacros.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Jul 27 2004.
//  Swift port of PSKMacros.m.
//

import Cocoa

//  Plist keys (must match Plist.h byte-for-byte).
private let kPSKMessages = "PSK Messages"
private let kPSKMessageTitles = "PSK MessageTitles"
private let kPSKOptMessages = "PSK Option Messages"
private let kPSKOptMessageTitles = "PSK Option MessageTitles"
private let kPSKShiftMessages = "PSK Shift Messages"
private let kPSKShiftMessageTitles = "PSK Shift MessageTitles"

/* local (were global C functions, used only in this file) */
private func pskMessageKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kPSKOptMessages
	case 2:  return kPSKShiftMessages
	default: return kPSKMessages
	}
}

private func pskTitleKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kPSKOptMessageTitles
	case 2:  return kPSKShiftMessageTitles
	default: return kPSKMessageTitles
	}
}

@objc(PSKMacros)
class PSKMacros: MacroSheet {

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
			( macroInterface as? PSK )?.selectView()
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
		pref.setString( "", forKey: pskMessageKey( index ) )
		pref.setString( "", forKey: pskTitleKey( index ) )
	}

	//  update all macros from the plist (called after fetchPlist )
	@objc(updateFromPlist:option:)
	@discardableResult
	func updateFromPlist( _ pref: Preferences, option index: Int32 ) -> Bool {
		updateFromPlist( pref, messageKey: pskMessageKey( index ), titleKey: pskTitleKey( index ) )
		return true
	}

	//  fetch all macros to save to the plist (called befoire savePlist )
	@objc(retrieveForPlist:option:)
	func retrieveForPlist( _ pref: Preferences, option index: Int32 ) {
		retrieveForPlist( pref, messageKey: pskMessageKey( index ), titleKey: pskTitleKey( index ) )
	}
}
