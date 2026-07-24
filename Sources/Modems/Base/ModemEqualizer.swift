//
//  ModemEqualizer.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 11/29/06.
//  Swift port of ModemEqualizer.m.
//

import Cocoa

//  must match Plist.h
private let kEqualizer = " Equalizer"

@objc(ModemEqualizer)
class ModemEqualizer: NSWindow {

	//  outlets set by ModemEqualizer.nib through KVC -- names must match nib keys exactly
	@objc var view: NSView!
	@objc var power: NSMatrix!
	@objc var plot: ModemEqualizerPlot!

	private var deviceName: String = ""
	private var response = [Float]( repeating: 0, count: 15 )			// 0 to 2.8 kHz in 200 Hz steps
	private var interpolated = [Float]( repeating: 0, count: 113 )		// 0 to 2.8 kHz in 25 Hz steps

	private var controllingWindow: NSWindow?

	@objc(initSheetFor:)
	init( sheetFor name: String )
	{
		super.init( contentRect: NSRect( x: 0, y: 0, width: 100, height: 100 ), styleMask: .titled, backing: .buffered, defer: false )
		deviceName = name
		if Bundle.main.loadNibNamed( "ModemEqualizer", owner: self, topLevelObjects: nil ) {
			setFrame( view.bounds, display: false )
			contentView?.addSubview( view )
			if power != nil { setFlatResponse() }
		}
	}

	//  ModemEqualizer is only ever created programmatically via -initSheetFor:;
	//  NSWindow's init(coder:) is itself unavailable.
	@available(*, unavailable)
	required init?( coder: NSCoder )
	{
		fatalError( "init(coder:) has not been implemented" )
	}

	private func setInterface( _ object: NSControl, to selector: Selector )
	{
		object.action = selector
		object.target = self
	}

	//  C truncated the float toward zero when assigning to int; guard against
	//  NaN / infinity (a caller can pass an arbitrary frequency to -amplitude:)
	//  the way DisplayColor.cInt does, then clamp to the valid table range.
	@inline(__always)
	private func clampedIndex( _ f: Float, max: Int ) -> Int {
		if f.isNaN { return 0 }
		let t = f.rounded( .towardZero )
		if t <= 0 { return 0 }
		if t >= Float( max ) { return max }
		return Int( t )
	}

	private func interpolate( _ v: Float ) -> Float
	{
		let i = clampedIndex( v/25 + 0.5, max: 112 )
		return interpolated[i]
	}

	private func interpolateRough( _ v: Float ) -> Float
	{
		var t = v/100
		if !t.isFinite { t = 0 }
		var i = Int( t ) / 2
		//  original read response[i] and response[i+1]; at v = 2800 that reached
		//  response[15], one element past the end of the 15-slot table.  Clamp i
		//  so the read stays in bounds; response[14] == response[13] == response[12]
		//  (set below), so the clamped value is identical for every reachable input.
		if i < 0 { i = 0 } else if i > 13 { i = 13 }
		let y1 = response[i]
		let y2 = response[i+1]
		var u = v/100 - Float( i*2 )
		u *= 0.5
		return y2*u + y1*( 1.0 - u )
	}

	private func setResponseFromMatrix()
	{
		var raw = [Float]( repeating: 0, count: 15 )

		//  set response, limiting below 400 Hz and above 2.4 kHz and also limiting to 3 dB.
		for i in 2..<13 {
			raw[i] = power.cell( atRow: i-2, column: 0 )?.floatValue ?? 0
			//  sanity check
			if raw[i] <= 0.01 { raw[i] = 0.01 }
		}
		raw[0] = raw[2]; raw[1] = raw[2]
		raw[14] = raw[12]; raw[13] = raw[12]

		var maxv: Float = -100
		for i in 0..<15 { if raw[i] > maxv { maxv = raw[i] } }
		for i in 0..<15 {
			raw[i] /= maxv
			if raw[i] < 0.43 { raw[i] = 0.43 }			//  limit to 3.5 dB worth of adjustment
		}

		//  get sqrt (voltage response)
		for i in 0..<15 { response[i] = Float( sqrt( 1.0/Double( raw[i] ) ) ) }

		//  roughly interpolate into 25 hz resolution
		for i in 0..<113 { interpolated[i] = interpolateRough( Float( i )*25.0 ) }

		//  Gaussian filter
		for _ in 0..<4 {
			//  low pass
			var state = interpolated[0]
			for i in 0..<113 {
				state = state*0.2 + interpolated[i]*0.8
				interpolated[i] = state
			}
			//  symmetricize
			state = interpolated[112]
			var i = 112
			while i >= 0 {
				state = state*0.2 + interpolated[i]*0.8
				interpolated[i] = state
				i -= 1
			}
		}
		if plot != nil {
			var logv = [Float]( repeating: 0, count: 81 )
			for i in 0..<81 { logv[i] = Float( 20.0*log10( Double( interpolate( 400.0 + 25.0*Float( i ) ) ) ) ) }
			plot.setResponse( &logv )
			plot.display()
		}
	}

	//  returns amplitude (between 0.4 and 2.5) for a given frequency
	//  this value should not drop much below 1.0 or rise much above 2.0.
	@objc(amplitude:)
	func amplitude( _ frequency: Float ) -> Float
	{
		var v = interpolate( frequency )
		if v < 0.8 { v = 0.8 } else if v > 2.5 { v = 2.5 }
		return v
	}

	@objc func setFlatResponse()
	{
		for i in 0..<11 {
			power.cell( atRow: i, column: 0 )?.floatValue = 1.0
		}
		setResponseFromMatrix()
	}

	@objc(showMacroSheetIn:)
	func showMacroSheet( in window: NSWindow )
	{
		controllingWindow = window
		NSApp.beginSheet( self, modalFor: window, modalDelegate: nil, didEnd: nil, contextInfo: nil )
	}

	@objc(done:)
	func done( _ sender: Any? )
	{
		setResponseFromMatrix()
		NSApp.endSheet( self )
		if let controllingWindow = controllingWindow { orderOut( controllingWindow ) }
	}

	@objc(responseUpdated:)
	func responseUpdated( _ sender: Any? )
	{
		setResponseFromMatrix()
	}

	//  plist
	@objc(setupDefaultPreferences:)
	func setupDefaultPreferences( _ pref: Preferences )
	{
		let defaultNumber = NSNumber( value: Float( 1.0 ) )
		let array = [NSNumber]( repeating: defaultNumber, count: 11 )
		pref.setArray( array, forKey: deviceName + kEqualizer )
	}

	@objc(updateFromPlist:)
	func updateFromPlist( _ pref: Preferences )
	{
		let array = pref.array( forKey: deviceName + kEqualizer )
		for i in 0..<11 {
			let number = array?[i] as? NSNumber ?? NSNumber( value: Float( 1.0 ) )
			//  set format in cell to be 2 decimal places
			power.cell( atRow: i, column: 0 )?.stringValue = String( format: "%.2f", number.floatValue )
		}
		setResponseFromMatrix()
	}

	@objc(retrieveForPlist:)
	func retrieveForPlist( _ pref: Preferences )
	{
		//  update the dictionary from the sheet
		var number = [NSNumber]()
		for i in 0..<11 {
			number.append( NSNumber( value: power.cell( atRow: i, column: 0 )?.floatValue ?? 0 ) )
		}
		pref.setArray( number, forKey: deviceName + kEqualizer )
	}
}
