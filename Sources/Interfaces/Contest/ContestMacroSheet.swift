//
//  ContestMacroSheet.swift
//  cocoaModem
//
//  Created by Kok Chen on 10/15/04.
//  Swift port of ContestMacroSheet.m.
//

import Cocoa

@objc(ContestMacroSheet)
class ContestMacroSheet: MacroSheet {

	//  outlet set by ContestMacroSheet.nib through KVC
	@objc var contestSheetName: NSTextField!

	//  messageStore/captionStore hold the getMessageObject / getCaptionObject
	//  result, which is an NSString (no '~') or an NSArray -- keep it loosely typed.
	private var messageStore: NSObject = "" as NSString
	private var captionStore: NSObject = "" as NSString
	//  ContestManager's full @interface is not exposed to Swift (only @class), so it
	//  is held loosely and messaged by selector.
	private weak var contestManager: NSObject?

	//  mirrors ContestMacroSheet -initSheet : [ super init ] (defaults) then the
	//  contest setup, then loads the ContestMacroSheet nib instead of MacroSheet's.
	override func loadSheetNib() {
		messageStore = "" as NSString
		captionStore = messageStore
		contestManager = nil
		updateFromMessageObject( messageStore, titleObject: captionStore )

		if Bundle.main.loadNibNamed( "ContestMacroSheet", owner: self, topLevelObjects: nil ) {
			if view != nil {
				setFrame( view.bounds, display: false )
				contentView?.addSubview( view )
			}
		}
	}

	@objc(delegateTextChangesTo:)
	func delegateTextChanges( to manager: NSObject? ) {
		contestManager = manager
		//  NSMatrix.delegate is typed (any NSMatrixDelegate)? in Swift; ContestManager
		//  does not declare that conformance, so set it through KVC as the original -setDelegate: did.
		titleMatrix?.setValue( manager, forKey: "delegate" )
		macroMatrix?.setValue( manager, forKey: "delegate" )
	}

	@objc(setName:)
	func setName( _ str: String? ) {
		contestSheetName?.stringValue = str ?? ""
	}

	@objc func messages() -> NSString? {
		messageStore = getMessageObject()
		return messageStore as? NSString
	}

	@objc func captions() -> NSString? {
		captionStore = getCaptionObject()
		return captionStore as? NSString
	}

	//  macro storage delimited by ~ characters
	@objc(setMessages:)
	func setMessages( _ mString: String? ) {
		messageStore = ( mString ?? "" ) as NSString
		updateFromMessageObject( messageStore, titleObject: captionStore )
	}

	@objc(setCaptions:)
	func setCaptions( _ tString: String? ) {
		captionStore = ( tString ?? "" ) as NSString
		updateFromMessageObject( messageStore, titleObject: captionStore )
	}

	//  button macros for contest
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
		if str[0] == CChar( UInt8( ascii: "s" ) ) && str[1] == CChar( UInt8( ascii: "l" ) ) {
			//  save file
			if contestManager != nil { _ = contestManager?.perform( NSSelectorFromString( "actualSaveContest" ) ) }
			return true
		}
		return false
	}

	@objc(showMacroSheet:)
	func showMacroSheet( _ window: NSWindow ) {
		controllingWindow = window
		NSApp.beginSheet( self, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil )
		//  [ NSApp runModalForWindow:self ] ;
		//  dont use modal mode so we can show dictionary
	}

	override func performDone() {
		( modem as? ContestInterface )?.updateContestMacroButtons()
		NSApp.endSheet( self )
		orderOut( controllingWindow )
	}
}
