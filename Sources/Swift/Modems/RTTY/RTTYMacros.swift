//
//  RTTYMacros.swift
//  cocoaModem
//
//  Created by Kok Chen on Sat Jul 03 2004.
//  Swift port of RTTYMacros.m.
//

import Cocoa

//  Plist keys (must match Plist.h byte-for-byte).
private let kRTTYMessages = "RTTY Messages"
private let kRTTYMessageTitles = "RTTY MessageTitles"
private let kRTTYOptMessages = "RTTY Option Messages"
private let kRTTYOptMessageTitles = "RTTY Option MessageTitles"
private let kRTTYShiftMessages = "RTTY Shift Messages"
private let kRTTYShiftMessageTitles = "RTTY Shift MessageTitles"

private func rttyMessageKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kRTTYOptMessages
	case 2:  return kRTTYShiftMessages
	default: return kRTTYMessages
	}
}

private func rttyTitleKey( _ index: Int32 ) -> String {
	switch index {
	case 1:  return kRTTYOptMessageTitles
	case 2:  return kRTTYShiftMessageTitles
	default: return kRTTYMessageTitles
	}
}

@objc(RTTYMacros)
class RTTYMacros: MacroSheet {

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
		if str[0] == CChar( UInt8( ascii: "b" ) ) {
			// bandwidth  (RTTYInterface is the visible superclass that declares -selectBandwidth:)
			switch str[1] {
			case CChar( UInt8( ascii: "1" ) ):
				( macroInterface as? RTTYInterface )?.selectBandwidth( 0 )
			case CChar( UInt8( ascii: "2" ) ):
				( macroInterface as? RTTYInterface )?.selectBandwidth( 1 )
			case CChar( UInt8( ascii: "3" ) ):
				( macroInterface as? RTTYInterface )?.selectBandwidth( 2 )
			default:
				break
			}
			return true
		}
		if str[0] == CChar( UInt8( ascii: "d" ) ) {
			// demodulator
			switch str[1] {
			case CChar( UInt8( ascii: "1" ) ):
				( macroInterface as? RTTYInterface )?.selectDemodulator( 4 )
			case CChar( UInt8( ascii: "2" ) ):
				( macroInterface as? RTTYInterface )?.selectDemodulator( 3 )
			case CChar( UInt8( ascii: "3" ) ):
				( macroInterface as? RTTYInterface )?.selectDemodulator( 2 )
			default:
				break
			}
			return true
		}
		return false
	}

	//  set up defaults before Plist is fetched
	@objc(setupDefaultPreferences:option:)
	func setupDefaultPreferences( _ pref: Preferences, option index: Int32 ) {
		if nameOutlet != nil {
			if index == 0 { nameOutlet.stringValue = "Macros" }
			if index == 1 { nameOutlet.stringValue = "Option Macros" }
			if index == 2 { nameOutlet.stringValue = "Option-Shift Macros" }
		}
		pref.setString( "", forKey: rttyMessageKey( index ) )
		pref.setString( "", forKey: rttyTitleKey( index ) )
	}

	//  update all macros from the plist (called after fetchPlist )
	@objc(updateFromPlist:option:)
	@discardableResult
	func updateFromPlist( _ pref: Preferences, option index: Int32 ) -> Bool {
		updateFromPlist( pref, messageKey: rttyMessageKey( index ), titleKey: rttyTitleKey( index ) )
		return true
	}

	//  fetch all macros to save to the plist (called before savePlist )
	@objc(retrieveForPlist:option:)
	func retrieveForPlist( _ pref: Preferences, option index: Int32 ) {
		retrieveForPlist( pref, messageKey: rttyMessageKey( index ), titleKey: rttyTitleKey( index ) )
	}
}
