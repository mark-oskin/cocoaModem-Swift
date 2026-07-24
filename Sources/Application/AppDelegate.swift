//
//  AppDelegate.swift
//  cocoaModem
//
//  Created by Kok Chen on 7/26/05.
//  Renamed from AESupport.m 10/4/09.
//
//  Swift port of AppDelegate.m.  This is a subclass of NSScriptCommand (kept for
//  historical fidelity) that acts as the delegate of NSApplication and intercepts
//  the AppleScript key-value accessors for the application scripting class.
//
//  NSScriptCommand only exposes -initWithCommandDescription: as a designated
//  initializer in Swift, so we hand it a throwaway command description.  This
//  object is never executed as an actual script command (the scripting system
//  creates its own command instances); it only ever serves as the app delegate.
//

import Cocoa

//  throwaway command description so we can call NSScriptCommand's designated init
private func cocoaModemDelegateCommandDescription() -> NSScriptCommandDescription {
	let dict: [String: Any] = [
		"CommandClass": "NSScriptCommand",
		"AppleEventClassCode": "capp",
		"AppleEventCode": "dumy",
	]
	return NSScriptCommandDescription( suiteName: "cocoaModem", commandName: "cocoaModemInternalDelegate", dictionary: dict )!
}

@objc(AppDelegate)
class AppDelegate: NSScriptCommand, NSApplicationDelegate {

	private var app: Application!
	private var stdManager: StdManager!

	private var windowIsVisibleFlag: Bool = true
	private var isLiteFlag: Bool = false

	@objc func appLevel() -> Int32
	{
		return 1
	}

	@objc(initFromApplication:)
	init( fromApplication app: Application )
	{
		super.init( commandDescription: cocoaModemDelegateCommandDescription() )
		isLiteFlag = false
		windowIsVisibleFlag = true
		self.app = app
		stdManager = app.stdManagerObject()
		NSApplication.shared.delegate = self
	}

	required init?( coder: NSCoder )
	{
		super.init( commandDescription: cocoaModemDelegateCommandDescription() )
	}

	@objc func application() -> Application!
	{
		return app
	}

	@objc func auralMonitor() -> AnyObject!
	{
		return app.auralMonitor()
	}

	@objc func audioManager() -> AudioManager!
	{
		return app.audioManager()
	}

	@objc func isLite() -> Bool
	{
		return isLiteFlag
	}

	@objc(setIsLite:)
	func setIsLite( _ state: Bool )
	{
		isLiteFlag = state
	}

	@objc func windowIsVisible() -> Bool
	{
		return windowIsVisibleFlag
	}

	@objc(setWindowIsVisible:)
	func setWindowIsVisible( _ state: Bool )
	{
		windowIsVisibleFlag = state
	}

	//  called from Application (delegate of NSApplication)
	@objc func application( _ sender: NSApplication, delegateHandlesKey key: String ) -> Bool
	{
		//  Classes
		if key == "windowState" { return true }
		if key == "windowPosition" { return true }
		if key == "watchdogTimer" { return true }
		if key == "interactiveInterface" { return true }
		if key == "contestInterface" { return true }
		if key == "scriptVersion" { return true }
		if key == "version" { return true }
		if key == "rttyModem" { return true }
		if key == "dualRTTYModem" { return true }
		if key == "widebandRTTYModem" { return true }
		if key == "pskModem" { return true }
		if key == "hellModem" { return true }
		if key == "cwModem" { return true }
		if key == "mfskModem" { return true }
		if key == "qso" { return true }
		if key == "modemName" { return true }

		//  deprecated
		if key == "modemMode" { return true }
		if key == "pskModulation" { return true }
		if key == "qsoCall" { return true }
		if key == "qsoName" { return true }
		if key == "pskRxAOffset" { return true }
		if key == "pskRxBOffset" { return true }
		if key == "pskTxAOffset" { return true }
		if key == "pskTxBOffset" { return true }

		return false
	}

	//  AppleScript Classes

	@objc func qso() -> QSO!
	{
		return stdManager.qsoObject()
	}

	@objc func interactiveInterface() -> ModemManager!
	{
		return stdManager
	}

	@objc func contestInterface() -> ModemManager!
	{
		return stdManager
	}

	@objc func watchdogTimer() -> ModemManager!
	{
		return stdManager
	}

	@objc func scriptVersion() -> Int32
	{
		return 3
	}

	@objc func version() -> String!
	{
		return Bundle.main.object( forInfoDictionaryKey: "CFBundleVersion" ) as? String
	}

	@objc func rttyModem() -> Modem!
	{
		return stdManager.rttyModem()
	}

	@objc func widebandRTTYModem() -> Modem!
	{
		return stdManager.wfRTTYModem()
	}

	@objc func dualRTTYModem() -> Modem!
	{
		return stdManager.dualRTTYModem()
	}

	@objc func pskModem() -> Modem!
	{
		return stdManager.pskModem()
	}

	@objc func hellModem() -> Modem!
	{
		return stdManager.hellschreiberModem()
	}

	@objc func cwModem() -> Modem!
	{
		return stdManager.cwModem()
	}

	@objc func mfskModem() -> Modem!
	{
		return stdManager.mfskModem()
	}

	@objc func modemName() -> String!
	{
		return stdManager.selectedModemName()
	}

	//  we are delegate to NSApplication
	//  call application to execute termination code
	@objc func applicationShouldTerminate( _ sender: NSApplication ) -> NSApplication.TerminateReply
	{
		return app.terminate()
	}

	@objc func windowState() -> Bool
	{
		return stdManager.windowState()
	}

	@objc(setWindowState:)
	func setWindowState( _ state: Bool )
	{
		stdManager.setWindowState( state )
	}

	@objc func windowPosition() -> NSAppleEventDescriptor
	{
		let point = stdManager.windowPosition()
		let x = Int32( point.x + 0.5 )
		let y = Int32( point.y + 0.5 )

		let desc = NSAppleEventDescriptor.list()
		desc.insert( NSAppleEventDescriptor( int32: x ), at: 1 )
		desc.insert( NSAppleEventDescriptor( int32: y ), at: 2 )
		return desc
	}

	@objc(setWindowPosition:)
	func setWindowPosition( _ point: NSAppleEventDescriptor )
	{
		if point.numberOfItems == 2 {
			let xDesc = point.atIndex( 1 )
			let x = xDesc?.int32Value ?? 0
			let yDesc = point.atIndex( 2 )
			let y = yDesc?.int32Value ?? 0
			stdManager.setWindowPosition( NSMakePoint( CGFloat( x ), CGFloat( y ) ) )
		}
	}

	//  the following supports the deprecated AppleScripts
	@objc func modemMode() -> Int32
	{
		return app.interface().modemMode()
	}

	@objc(setModemMode:)
	func setModemMode( _ mode: Int32 )
	{
		app.interface().setModemMode( mode )
	}

	@objc func pskModulation() -> Int32
	{
		return app.interface().pskModulation()
	}

	@objc(setPskModulation:)
	func setPskModulation( _ modulation: Int32 )
	{
		app.interface().setPskModulation( modulation )
	}

	@objc func qsoCall() -> String
	{
		if let qso = stdManager.qsoObject() { return qso.callsign() }
		return ""
	}

	@objc(setQsoCall:)
	func setQsoCall( _ setstring: String )
	{
		if let qso = stdManager.qsoObject() { qso.setCallsign( setstring ) }
	}

	@objc func qsoName() -> String
	{
		if let qso = stdManager.qsoObject() { return qso.opName() }
		return ""
	}

	@objc(setQsoName:)
	func setQsoName( _ setstring: String )
	{
		if let qso = stdManager.qsoObject() { qso.setOpName( setstring ) }
	}

	//  to be deprecated (moved to faces)
	@objc func pskRxAOffset() -> String
	{
		var v: Float = 0
		if let psk = stdManager.pskModem() as? PSK { v = psk.getRxOffset( 0 ) }
		return String( format: "%f", v )
	}

	//  to be deprecated (moved to faces)
	@objc func pskRxBOffset() -> String
	{
		var v: Float = 0
		if let psk = stdManager.pskModem() as? PSK { v = psk.getRxOffset( 1 ) }
		return String( format: "%f", v )
	}

	//  to be deprecated (moved to faces)
	@objc func pskTxAOffset() -> String
	{
		var v: Float = 0
		if let psk = stdManager.pskModem() as? PSK { v = psk.getTxOffset( 0 ) }
		return String( format: "%f", v )
	}

	//  to be deprecated (moved to faces)
	@objc func pskTxBOffset() -> String
	{
		var v: Float = 0
		if let psk = stdManager.pskModem() as? PSK { v = psk.getTxOffset( 1 ) }
		return String( format: "%f", v )
	}

	//  to be deprecated (moved to faces)
	@objc(setPskRxAOffset:)
	func setPskRxAOffset( _ freq: String )
	{
		if let psk = stdManager.pskModem() as? PSK { psk.setRxOffset( 0, freq: ( freq as NSString ).floatValue ) }
	}

	//  to be deprecated (moved to faces)
	@objc(setPskRxBOffset:)
	func setPskRxBOffset( _ freq: String )
	{
		if let psk = stdManager.pskModem() as? PSK { psk.setRxOffset( 1, freq: ( freq as NSString ).floatValue ) }
	}

	//  to be deprecated (moved to faces)
	@objc(setPskTxAOffset:)
	func setPskTxAOffset( _ freq: String )
	{
		if let psk = stdManager.pskModem() as? PSK { psk.setTxOffset( 0, freq: ( freq as NSString ).floatValue ) }
	}

	//  to be deprecated (moved to faces)
	@objc(setPskTxBOffset:)
	func setPskTxBOffset( _ freq: String )
	{
		if let psk = stdManager.pskModem() as? PSK { psk.setTxOffset( 1, freq: ( freq as NSString ).floatValue ) }
	}
}
