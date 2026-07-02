//
//  MacroSheet.swift
//  cocoaModem
//
//  Created by Kok Chen on Mon May 31 2004.
//  Swift port of MacroSheet.m.
//

import Cocoa

private let macroFIGSCODE: unichar = 0x1b
private let macroLTRSCODE: unichar = 0x1f

//  macros storage (in Plist) strings are separated by ~ characters
//  (global C function in the original; now file-private -- only used here).
private func nextMsg( _ full: inout String ) -> String
{
	let s = full as NSString
	let length = s.length
	var n = 0
	var ch = 0
	while n < length {
		ch = Int( s.character( at: n ) ) & 0x7f
		if ch == 0x7e /* '~' */ { break }
		n += 1
	}
	let result: String = ( n == 0 ) ? "" : s.substring( with: NSRange( location: 0, length: n ) )

	//  update full string to start at next field
	if ch == 0x7e { n += 1 }
	full = s.substring( from: n )

	return result
}

@objc(MacroSheet)
class MacroSheet: NSWindow {

	//  outlets set by MacroSheet.nib through KVC -- names must match nib keys exactly.
	//  'name' is served through setValue(_:forKey:) below because ContestMacroSheet
	//  reuses the -setName: selector for its own purpose (which collides with the
	//  synthesized setter of an @objc 'name' property in Swift).
	var nameOutlet: NSTextField!
	@objc var view: NSView!
	@objc var titleMatrix: NSMatrix!
	@objc var macroMatrix: NSMatrix!
	@objc var importButton: NSButton!
	@objc var exportButton: NSButton!

	weak var controllingWindow: NSWindow?
	private weak var userInfo: UserInfo?
	private weak var qso: QSO?
	weak var modem: MacroInterface?
	private var macroBuf: String = ""
	var excessTransmitMacros: Int32 = 0

	//  MacroSheet.nib connects an outlet named "name"; route it to nameOutlet.
	override func setValue( _ value: Any?, forKey key: String ) {
		if key == "name" { nameOutlet = value as? NSTextField ; return }
		super.setValue( value, forKey: key )
	}

	override func value( forKey key: String ) -> Any? {
		if key == "name" { return nameOutlet }
		return super.value( forKey: key )
	}

	//  mirrors -init : defaults only (Swift stored-property initializers supply them).
	//  [ [ MacroSheet alloc ] init ] funnels through NSWindow's convenience -init
	//  into this designated initializer.
	override init( contentRect rect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool ) {
		super.init( contentRect: rect, styleMask: style, backing: backingStoreType, defer: flag )
	}

	@available(*, unavailable)
	required init?( coder: NSCoder ) {
		fatalError( "init(coder:) has not been implemented" )
	}

	//  mirrors -initSheet.  The @objc(initSheet) selector is preserved exactly;
	//  the () parameter maps to a zero-argument Objective-C selector.
	@objc(initSheet)
	convenience init( sheet: () ) {
		self.init( contentRect: NSRect( x: 0, y: 0, width: 100, height: 100 ), styleMask: .titled, backing: .buffered, defer: false )
		loadSheetNib()
	}

	//  overridden by ContestMacroSheet to load a different nib
	@objc func loadSheetNib() {
		if Bundle.main.loadNibNamed( "MacroSheet", owner: self, topLevelObjects: nil ) {
			if view != nil {
				setFrame( view.bounds, display: false )
				contentView?.addSubview( view )
			}
			excessTransmitMacros = 0
		}
	}

	@objc(setUserInfo:qso:modem:canImport:)
	func setUserInfo( _ info: UserInfo?, qso qsoObj: QSO?, modem inModem: MacroInterface?, canImport: Bool ) {
		userInfo = info
		qso = qsoObj
		modem = inModem
	}

	//  this allows the Macrosheet to target a particular modem's contest interface
	@objc(setModem:)
	func setModem( _ inModem: MacroInterface? ) {
		modem = inModem
	}

	@objc(showMacroSheet:modem:)
	func showMacroSheet( _ window: NSWindow, modem inModem: MacroInterface? ) {
		controllingWindow = window
		modem = inModem
		NSApp.beginSheet( self, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil )
		//  [ NSApp runModalForWindow:self ] ;
		//  dont use modal mode so we can show dictionary
	}

	@objc(title:)
	func title( _ index: Int32 ) -> String? {
		return titleMatrix?.cell( atRow: Int( index ), column: 0 )?.stringValue
	}

	@objc func titles() -> NSMatrix? {
		return titleMatrix
	}

	@objc(macro:)
	func macro( _ index: Int32 ) -> String? {
		return macroMatrix?.cell( atRow: Int( index ), column: 0 )?.stringValue
	}

	/* local */
	//  append macro and return end of string
	//		\n		new line
	//		%b		brag tape   (in userInfo)
	//		%c		myCall		(in userInfo)
	//		%h		name		(in userInfo)
	private func macroFor( _ c: Int32 ) -> String {
		//  for now no macros
		return ""
	}

	//	v0.89	MacroScript
	@objc(executeMacroScript:)
	func executeMacroScript( _ str: UnsafeMutablePointer<CChar>? ) -> Bool {
		guard let str = str else { return false }

		if str[0] != CChar( UInt8( ascii: "a" ) ) { return false }

		let index = Int32( str[1] ) - Int32( UInt8( ascii: "0" ) )
		if index >= 0 && index < 6 {
			let application = ( NSApp.delegate as? AppDelegate )?.application()
			application?.macroScripts()?.executeMacroScript( index )
			return true
		}
		return false
	}

	//  this is overridden by subclasses to execute button macros
	@objc(executeButtonMacro:modem:)
	func executeButtonMacro( _ str: UnsafeMutablePointer<CChar>?, modem macroInterface: MacroInterface? ) -> Bool {
		// override
		return false
	}

	@objc(appendToMessageBuf:)
	func appendToMessageBuf( _ string: String? ) {
		guard let string = string else { return }
		macroBuf = macroBuf + string
	}

	//	v0.70 changed argument from const char* to NSString
	private func expandMacroString( _ macroStringIn: String, modem macroInterface: MacroInterface? ) -> String {
		macroBuf = ""

		let original = macroStringIn						//  v0.78 changed from original = macroString
		var macroString = macroStringIn
		if ( macroString as NSString ).length > 1000 { macroString = ( macroString as NSString ).substring( to: 1000 ) }
		let length = ( macroString as NSString ).length
		var unichars = [unichar]( repeating: 0, count: 1024 )
		( macroString as NSString ).getCharacters( &unichars, range: NSRange( location: 0, length: length ) )

		func ch( _ idx: Int ) -> unichar { return idx < 1024 ? unichars[idx] : 0 }

		var i = 0
		while i < length {
			var c = ch( i ) ; i += 1
			switch Int( c ) & 0xff {
			case Int( UInt8( ascii: "%" ) ):
				c = ch( i ) ; i += 1
				var n = 1
				if c == unichar( UInt8( ascii: "0" ) ) || c == unichar( UInt8( ascii: "3" ) ) || c == unichar( UInt8( ascii: "4" ) ) {
					n = Int( c ) - Int( UInt8( ascii: "0" ) )
					c = ch( i ) ; i += 1			// v0.78
				}
				switch Int( c ) {
				case Int( UInt8( ascii: "b" ) ), Int( UInt8( ascii: "c" ) ), Int( UInt8( ascii: "h" ) ), Int( UInt8( ascii: "s" ) ):
					if let userInfo = userInfo { appendToMessageBuf( userInfo.macroFor( Int32( c ) ) ) }
				case Int( UInt8( ascii: "x" ) ), Int( UInt8( ascii: "X" ) ), Int( UInt8( ascii: "C" ) ), Int( UInt8( ascii: "H" ) ),
					 Int( UInt8( ascii: "p" ) ), Int( UInt8( ascii: "P" ) ), Int( UInt8( ascii: "t" ) ), Int( UInt8( ascii: "T" ) ):
					if let qso = qso { appendToMessageBuf( qso.macroFor( Int32( c ) ) ) }
				case Int( UInt8( ascii: "n" ) ), Int( UInt8( ascii: "N" ) ), Int( UInt8( ascii: "o" ) ):
					if let qso = qso {
						if n == 1 { appendToMessageBuf( qso.macroFor( Int32( c ) ) ) } else { appendToMessageBuf( qso.macroFor( Int32( c ), count: Int32( n ) ) ) }
					}
				case Int( UInt8( ascii: "[" ) ):
					var button = [CChar]( repeating: 0, count: 3 )
					button[0] = CChar( truncatingIfNeeded: Int( ch( i ) ) & 0xff ) ; i += 1
					button[1] = CChar( truncatingIfNeeded: Int( ch( i ) ) & 0xff ) ; i += 1
					button[2] = 0
					let close = Int( ch( i ) ) & 0xff ; i += 1
					if close != Int( UInt8( ascii: "]" ) ) {
						Messages.alert( withMessageText: NSLocalizedString( "Bad macro", comment: "" ), informativeText: original )
					}
					else {
						_ = button.withUnsafeMutableBufferPointer { executeButtonMacro( $0.baseAddress, modem: macroInterface ) }
					}
				default:
					appendToMessageBuf( macroFor( Int32( c ) ) )
				}
			case Int( UInt8( ascii: "\\" ) ):
				c = ch( i ) ; i += 1
				switch Int( c ) {
				//  0.68
				case Int( UInt8( ascii: "l" ) ):
					appendToMessageBuf( String( utf16CodeUnits: [macroLTRSCODE], count: 1 ) )
				case Int( UInt8( ascii: "f" ) ):
					appendToMessageBuf( String( utf16CodeUnits: [macroFIGSCODE], count: 1 ) )
				case Int( UInt8( ascii: "n" ) ), Int( UInt8( ascii: "p" ) ): /* already paired as \r\n at the AFSK generator */
					appendToMessageBuf( "\n" )
				case Int( UInt8( ascii: "r" ) ):
					appendToMessageBuf( "\r" )
				default:
					macroBuf = macroBuf + String( utf16CodeUnits: [c], count: 1 )		//  v0.70
				}
			default:
				macroBuf = macroBuf + String( utf16CodeUnits: [c], count: 1 )		//  v0.70
			}
		}
		// balanced out transmit macros (tx not balanced by rx within a macro)
		while true {
			let prev = excessTransmitMacros
			excessTransmitMacros -= 1
			if prev > 0 { macroBuf = macroBuf + "\u{1a}" /* 'Z'-'A'+1 */ } else { break }
		}
		return macroBuf
	}

	//  expand macro at index into an NSString, client releases
	@objc(expandMacro:modem:)
	func expandMacro( _ index: Int32, modem macroInterface: MacroInterface? ) -> String? {
		guard let msgField = macroMatrix?.cell( atRow: Int( index ), column: 0 ) else { return nil }

		let macro = msgField.stringValue
		if macro.isEmpty { return nil }

		excessTransmitMacros = 0
		return expandMacroString( macro, modem: macroInterface )		//  v0.70
	}

	//  set up defaults before Plist is fetched
	@objc(setupDefaultPreferences:messageKey:titleKey:)
	func setupDefaultPreferences( _ pref: Preferences, messageKey: String, titleKey: String ) {
	}

	private func has0x7e( _ str: String? ) -> Bool {
		guard let str = str as NSString? else { return false }
		let n = str.length
		for i in 0..<n {
			let uni = str.character( at: i )
			if ( uni / 256 ) == 0x7e { return true }
			if ( uni & 0xff ) == 0x7e { return true }
		}
		return false
	}

	//  v0.72 -- return as NSArray if there are ~ in the messages otherwise (to maintain compatibility) get messages into a long string separated by ~
	@objc func getMessageObject() -> NSObject {
		let n = macroMatrix?.numberOfRows ?? 0
		//   first check all strings to see if there is any ~
		var i = 0
		while i < n {
			let string = macroMatrix?.cell( atRow: i, column: 0 )?.stringValue
			if has0x7e( string ) { break }
			i += 1
		}
		if i >= n {
			//  no squiggles, use old method for compatibility
			var string = ""
			for j in 0..<n {
				if let msg = macroMatrix?.cell( atRow: j, column: 0 ) {
					let msgString = msg.stringValue
					if !msgString.isEmpty { string = string + msgString }
				}
				string = string + "~"
			}
			return string as NSString
		}
		let array = NSMutableArray( capacity: n )
		for j in 0..<n {
			if let msg = macroMatrix?.cell( atRow: j, column: 0 ) {
				array.add( msg.stringValue )
			}
			else { array.add( "" ) }
		}
		return array
	}

	//  v0.72 -- return as NSArray if there are ~ in the messages otherwise (to maintain compatibility) get messages into a long string separated by ~
	@objc func getCaptionObject() -> NSObject {
		let n = titleMatrix?.numberOfRows ?? 0
		var i = 0
		while i < n {
			let string = titleMatrix?.cell( atRow: i, column: 0 )?.stringValue
			if has0x7e( string ) { break }
			i += 1
		}
		if i >= n {
			var string = ""
			for j in 0..<n {
				if let msg = titleMatrix?.cell( atRow: j, column: 0 ) {
					let msgString = msg.stringValue
					if !msgString.isEmpty { string = string + msgString }
				}
				string = string + "~"
			}
			return string as NSString
		}
		let array = NSMutableArray( capacity: n )
		for j in 0..<n {
			if let msg = titleMatrix?.cell( atRow: j, column: 0 ) {
				array.add( msg.stringValue )
			}
			else { array.add( "" ) }
		}
		return array
	}

	//	v0.72 (was updateFromMessageString:titleString:)
	//  update macro fields from either ~ delimted strings or from NSArray of strings
	@objc(updateFromMessageObject:titleObject:)
	func updateFromMessageObject( _ msgObject: NSObject?, titleObject: NSObject? ) {
		var n = macroMatrix?.numberOfRows ?? 0
		if let string = msgObject as? String {		//  v0.93a
			var s = string
			for i in 0..<n {
				let result = nextMsg( &s )
				macroMatrix?.cell( atRow: i, column: 0 )?.stringValue = result
			}
		}
		else if let array = msgObject as? [Any] {
			var nn = n
			if nn > array.count { nn = array.count }
			for i in 0..<nn {
				macroMatrix?.cell( atRow: i, column: 0 )?.stringValue = ( array[i] as? String ) ?? ""
			}
		}
		n = titleMatrix?.numberOfRows ?? 0
		if let string = titleObject as? String {		//  v0.93a
			var s = string
			for i in 0..<n {
				let result = nextMsg( &s )
				titleMatrix?.cell( atRow: i, column: 0 )?.stringValue = result
			}
		}
		else if let array = titleObject as? [Any] {
			var nn = n
			if nn > array.count { nn = array.count }
			for i in 0..<nn {
				titleMatrix?.cell( atRow: i, column: 0 )?.stringValue = ( array[i] as? String ) ?? ""
			}
		}
		modem?.updateMacroButtons()
	}

	//	v0.72
	//  update macro fields from the plist (called after fetchPlist )
	@objc(updateFromPlist:messageKey:titleKey:)
	func updateFromPlist( _ pref: Preferences, messageKey: String, titleKey: String ) {
		let msgObject = pref.object( forKey: messageKey )
		let titleObject = pref.object( forKey: titleKey )

		updateFromMessageObject( msgObject as? NSObject, titleObject: titleObject as? NSObject )
	}

	//  v0.93a - fixed [ @"" class ]
	@objc(retrieveForPlist:messageKey:titleKey:)
	func retrieveForPlist( _ pref: Preferences, messageKey: String, titleKey: String ) {
		var object = getMessageObject()
		if object is NSString { pref.setString( object as? String, forKey: messageKey ) } else { pref.setArray( object as? [Any], forKey: messageKey ) }

		object = getCaptionObject()
		if object is NSString { pref.setString( object as? String, forKey: titleKey ) } else { pref.setArray( object as? [Any], forKey: titleKey ) }
	}

	//  override this in ContestMacroSheet
	@objc func performDone() {
		modem?.updateMacroButtons()
		// 	[ NSApp stopModal ] ;		sheet is not model
		NSApp.endSheet( self )
		orderOut( controllingWindow )
	}

	@objc(done:)
	func done( _ sender: Any? ) {
		performDone()
	}

	//  import macros
	@objc(import:)
	func `import`( _ sender: Any? ) {
		let open = NSOpenPanel()
		open.allowsMultipleSelection = false
		if open.runModal() == .OK, let path = open.url?.path {
			if let prefs = Preferences( path: path ) {
				prefs.fetchPlist( false )
				updateFromPlist( prefs, messageKey: kMessages, titleKey: kMessageTitles )
			}
		}
	}

	//  export macros
	@objc(export:)
	func export( _ sender: Any? ) {
		let save = NSSavePanel()
		if save.runModal() == .OK, let path = save.url?.path {
			if let prefs = Preferences( path: path ) {
				//  get the macros into this temp dictionary
				retrieveForPlist( prefs, messageKey: kMessages, titleKey: kMessageTitles )
				prefs.savePlist()
			}
		}
	}
}

//  Plist keys (must match Plist.h byte-for-byte; #define @"..." macros are not
//  visible to Swift, so they are redeclared here).
private let kMessages = "Messages"
private let kMessageTitles = "MessageTitles"
