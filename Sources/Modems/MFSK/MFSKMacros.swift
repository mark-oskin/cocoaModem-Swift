//
//  MFSKMacros.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 2/16/06.
//  Swift port of MFSKMacros.m.
//

import Cocoa

//  Plist keys (must match Plist.h byte-for-byte).
private let kMFSKMessages = "MFSK Messages"
private let kMFSKMessageTitles = "MFSK MessageTitles"
private let kMFSKOptMessages = "MFSK Option Messages"
private let kMFSKOptMessageTitles = "MFSK Option MessageTitles"
private let kMFSKShiftMessages = "MFSK Shift Messages"
private let kMFSKShiftMessageTitles = "MFSK Shift MessageTitles"

/* local (were global C functions, used only in this file) */
private func mfskMessageKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kMFSKOptMessages
	case 2:  return kMFSKShiftMessages
	default: return kMFSKMessages
	}
}

private func mfskTitleKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kMFSKOptMessageTitles
	case 2:  return kMFSKShiftMessageTitles
	default: return kMFSKMessageTitles
	}
}

@objc(MFSKMacros)
class MFSKMacros: MacroSheet {

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
		pref.setString( "", forKey: mfskMessageKey( index ) )
		pref.setString( "", forKey: mfskTitleKey( index ) )
	}

	//  update all macros from the plist (called after fetchPlist )
	@objc(updateFromPlist:option:)
	@discardableResult
	func updateFromPlist( _ pref: Preferences, option index: Int32 ) -> Bool {
		updateFromPlist( pref, messageKey: mfskMessageKey( index ), titleKey: mfskTitleKey( index ) )
		return true
	}

	//  fetch all macros to save to the plist (called befoire savePlist )
	@objc(retrieveForPlist:option:)
	func retrieveForPlist( _ pref: Preferences, option index: Int32 ) {
		retrieveForPlist( pref, messageKey: mfskMessageKey( index ), titleKey: mfskTitleKey( index ) )
	}
}
