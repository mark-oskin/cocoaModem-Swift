//
//  Speech.swift
//  cocoaModem 2.0
//
//  Swift port of Speech.m (Created by Kok Chen on 2/9/12).
//  Copyright 2012 Kok Chen, W7AY. All rights reserved.
//
//  Faithful 1:1 port of the original Objective-C class.  Behavior, selectors
//  and quirks (including original bugs, e.g. the '6'->'7' switch fall-through
//  in -expand:) are preserved exactly.
//
//  TODO: migrate to AVSpeechSynthesizer.  This pass intentionally keeps the
//  deprecated NSSpeechSynthesizer to avoid any behavior change; the resulting
//  deprecation warnings are expected.
//

import Cocoa

private let kVoiceBuffers = 256

//  ASCII code of a Character (helper for faithful C-style character switches).
private func A( _ c: Character ) -> Int32 { Int32( c.asciiValue! ) }

private func isStringBreak( _ character: Int32 ) -> Bool
{
	switch character {
	case A( " " ), A( "." ), A( "!" ), A( "?" ), A( "/" ), A( "," ), A( ":" ), A( ";" ), A( "\t" ), A( "\n" ), A( "\r" ):
		return true
	default:
		return false
	}
}

@objc(Speech)
class Speech: NSObject, NSSpeechSynthesizerDelegate {

	private var synth: NSSpeechSynthesizer!
	private var buffer = [NSMutableString]()
	private var lettersWord = NSMutableString()
	private var enunciate = NSMutableDictionary()
	private var enunciateKeys: [Any] = []
	private var producer = 0
	private var consumer = 0
	private var previousLetter: Int32 = 0
	private var needsSound = false
	private var enabled = false
	private var verbatim = false
	private var muted = false
	private var deferredDot = false
	private var deferredMinus = false
	private var useSpell = false
	private var timer: Timer?

	//	return YES if already spoken
	@discardableResult
	private func substitute( _ string: NSMutableString, _ original: String, _ differentString: String ) -> Bool
	{
		return string.replaceOccurrences( of: original, with: differentString, options: .caseInsensitive, range: NSMakeRange( 0, string.length ) ) > 0
	}

	@objc func tick( _ timer: Timer? )
	{
		var aggregate = NSMutableString()

		if needsSound {
			if producer != consumer {
				if synth.isSpeaking == false {
					//  gather up to 8 buffers
					for i in 0..<8 {
						if i == 0 { aggregate = NSMutableString( string: buffer[consumer] ) } else { aggregate.append( buffer[consumer] as String ) }
						consumer = ( consumer+1 ) % kVoiceBuffers
						if consumer == producer { break }
					}
					synth.startSpeaking( aggregate as String )
				}
			}
			if producer == consumer { needsSound = false }
		}
	}

	@objc(initWithVoice:)
	init( voice voiceID: String? )
	{
		super.init()

		lettersWord = NSMutableString()					//  v1.0
		previousLetter = 0
		//  v1.0 enunciation
		enunciate = NSMutableDictionary()
		enunciateKeys = []
		let name = "~/Library/Application Support/cocoaModem/Enunciate.txt"
		let path = ( name as NSString ).expandingTildeInPath
		if let ext = fopen( path, "r" ) {
			var string = [CChar]( repeating: 0, count: 257 )
			while true {
				string[0] = 0
				if fgets( &string, 256, ext ) == nil { break }
				//  replace eol by null and convert to NSString
				var s = 0
				while string[s] != 0 && string[s] != 0x0a && string[s] != 0x0d { s += 1 }
				string[s] = 0
				if let line = NSString( cString: string, encoding: String.Encoding.isoLatin1.rawValue ) {
					let range = line.range( of: " " )
					if range.location != NSNotFound {
						var key = ( line.substring( to: range.location ) as NSString ).uppercased
						key = " " + key + " "
						let value = line.substring( from: range.location + 1 )
						enunciate.setValue( value, forKey: key )
					}
				}
			}
			enunciateKeys = enunciate.allKeys
			fclose( ext )
		}
		synth = NSSpeechSynthesizer( voice: voiceID.map { NSSpeechSynthesizer.VoiceName( rawValue: $0 ) } )
		synth?.delegate = self
		for _ in 0..<kVoiceBuffers {
			let m = NSMutableString()
			m.setString( " " )
			buffer.append( m )
		}
		producer = 0
		consumer = 0
		needsSound = false
		enabled = false
		verbatim = false
		deferredDot = false
		muted = false
		useSpell = false
		timer = nil
	}

	deinit {
		if let timer = timer { timer.invalidate() }
	}

	@objc func speak( _ string: String )
	{
		synth.startSpeaking( string )
	}

	@objc func queuedSpeak( _ string: String )
	{
		buffer[producer].setString( string )
		producer = ( producer+1 ) % kVoiceBuffers
		needsSound = true
	}

	@objc func setVoice( _ name: String? )
	{
		if name == nil || name == "Default" {
			synth.setVoice( nil )
			return
		}
		synth.setVoice( NSSpeechSynthesizer.VoiceName( rawValue: name! ) )
	}

	@objc func setVoiceEnable( _ state: Bool )
	{
		if state == false {
			enabled = false
			if let timer = timer { timer.invalidate() }
			timer = nil
			synth.stopSpeaking()
			return
		}
		enabled = true
		if timer == nil { timer = Timer.scheduledTimer( timeInterval: 0.1, target: self, selector: #selector(tick(_:)), userInfo: self, repeats: true ) }
	}

	@objc func setVerbatim( _ state: Bool )
	{
		verbatim = state
	}

	@objc func setMute( _ state: Bool )
	{
		muted = state
		clearVoice()
	}

	@objc func setSpell( _ state: Bool )
	{
		useSpell = state
		clearVoice()
	}

	private func spell( _ asciiIn: Int32 )
	{
		var ascii = asciiIn
		if ascii >= A( "a" ) && ascii <= A( "z" ) { ascii += A( "A" ) - A( "a" ) }
		if ascii == previousLetter {
			if ascii == A( "\r" ) || ascii == A( "\n" ) || ascii == A( " " ) { return }
			lettersWord.append( "-" )
		}
		previousLetter = ascii

		switch ascii {
		case A( " " ):
			lettersWord.append( ", ," )
		case A( "A" ):
			lettersWord.append( " A " )
		case A( "V" ):
			lettersWord.append( " vee " )
		case A( "S" ):
			lettersWord.append( " s " )
		case A( "Z" ):
			lettersWord.append( " zed " )
		case A( "O" ):
			lettersWord.append( " oh " )
		case A( "U" ):
			lettersWord.append( " you " )
		case A( "I" ):
			lettersWord.append( " eye " )
		case A( "-" ):
			lettersWord.append( " minus" )
		case A( "/" ):
			lettersWord.append( ". slash" )
		case A( "?" ):
			lettersWord.append( ". question" )
		case A( "(" ):
			lettersWord.append( ". open parenthesis" )
		case A( ")" ):
			lettersWord.append( ". close parenthesis" )
		case A( "'" ):
			lettersWord.append( ". apostrophe" )
		case A( "=" ):
			lettersWord.append( ". equal" )
		case A( "%" ):
			lettersWord.append( ". percent" )
		case A( "\"" ):
			lettersWord.append( ". quote" )
		case A( "*" ):
			lettersWord.append( " star" )
			previousLetter = 0
		case A( "." ):
			lettersWord.append( "/period" )
		case A( "," ):
			lettersWord.append( "/comma" )
		case A( ":" ):
			lettersWord.append( ". colon" )
		case A( ";" ):
			lettersWord.append( ". semi colon." )
		case A( "\r" ), A( "\n" ):
			lettersWord.append( ". . new line." )
		default:
			lettersWord.append( " " )
			lettersWord.append( String( format: "%c", ascii ) )
		}

		if ascii == A( " " ) {
			producer = ( producer+1 ) % kVoiceBuffers
			buffer[producer].setString( lettersWord as String )
			buffer[producer].append( "." )
			lettersWord.setString( " " )
			needsSound = true
		}
		return
	}

	//	return YES if already spoken
	@discardableResult
	private func expand( _ string: NSMutableString ) -> Bool
	{
		var check: Int32
		var hasLetter: Bool, hasDigit: Bool, substituted: Bool, wasDigit: Bool, isDigit: Bool

		if verbatim || string.length < 1 { return false }

		string.setString( ( string as String ).lowercased() )

		check = Int32( string.character( at: 1 ) )
		if ( check == A( " " ) || check == A( "." ) || check == A( "." ) ) && string.length >= 2 { check = Int32( string.character( at: 1 ) ) }

		let original = NSString( string: string )

		let enunciateStringLookup = enunciate.object( forKey: original.uppercased ) as? String

		if let enunciateString = enunciateStringLookup {
			substitute( string, original as String, enunciateString )
			return true
		}

		//  v1.02a check for words with mixed letters and digits.  If so, spell it.
		//  first, substitute with known mixed letter/digits
		substituted = true
		switch check {
		case A( "1" ):
			if substitute( string, " 17m ",	" seventeen meters " ) { break }
			if substitute( string, " 15m ",	" fifteen meters " ) { break }
			if substitute( string, " 12m ",	" twelve meters " ) { break }
			if substitute( string, " 10m ",	" ten meters " ) { break }
			if substitute( string, " 17m.",	" seventeen meters " ) { break }
			if substitute( string, " 15m.",	" fifteen meters " ) { break }
			if substitute( string, " 12m.",	" twelve meters " ) { break }
			if substitute( string, " 10m.",	" ten meters " ) { break }
			substituted = false
		case A( "2" ):
			if substitute( string, " 20m ",	" twenty meters " ) { break }
			if substitute( string, " 20m.",	" twenty meters " ) { break }
			substituted = false
		case A( "3" ):
			if substitute( string, " 30m ",	" thirty meters " ) { break }
			if substitute( string, " 30m.",	" thirty meters " ) { break }
			substituted = false
		case A( "4" ):
			if substitute( string, " 40m ",	" forty meters " ) { break }
			if substitute( string, " 40m.",	" forty meters " ) { break }
			substituted = false
		case A( "5" ):
			if substitute( string, " 599 ",	" five nine nine, " ) { break }
			substituted = false
		case A( "6" ):
			if substitute( string, " 6m ",	" six meters " ) { break }
			substituted = false
			fallthrough
		case A( "7" ):
			if substitute( string, " 73 ",	" seven three, " ) { break }
			substituted = false
		case A( "8" ):
			if substitute( string, " 80m ",	" eighty meters " ) { break }
			if substitute( string, " 80m.",	" eighty meters " ) { break }
			substituted = false
		default:
			substituted = false
		}
		if substituted == false {
			var length = string.length
			hasLetter = false
			hasDigit = false
			for i in 1..<max( length, 1 ) {
				check = Int32( string.character( at: i ) )
				if check >= A( "0" ) && check <= A( "9" ) { hasDigit = true }
				if check >= A( "a" ) && check <= A( "z" ) { hasLetter = true }
			}
			if hasLetter == true && hasDigit == true {
				let enunciateString = NSString( string: string )
				buffer[producer].setString( " " )
				wasDigit = false
				length = enunciateString.length
				for i in 0..<length {
					check = Int32( enunciateString.character( at: i ) )
					isDigit = ( check >= A( "0" ) && check <= A( "9" ) )
					if isDigit == false && wasDigit == true { spell( A( " " ) ) }
					spell( check )
					wasDigit = isDigit
				}
				return true
			}
		}

		check = Int32( string.character( at: 1 ) )
		switch check {
		case A( "a" ), A( "A" ):
			if substitute( string, " a ",	" a-" ) { break }
			if substitute( string, " ag ",	" a-g " ) { break }
			if substitute( string, " ar ",	" a-r " ) { break }
			if substitute( string, " arrl ",	" a-double r ell " ) { break }
			if substitute( string, " arrl.",	" a-double r ell dot " ) { break }
			if substitute( string, " abt ",	" about " ) { break }
			if substitute( string, " agn ",	" again " ) { break }
			if substitute( string, " agn?",	" again? " ) { break }
			if substitute( string, " alc ",	" A L C " ) { break }
			if substitute( string, " agc ",	" A G C " ) { break }
		case A( "b" ), A( "B" ):
			if substitute( string, " btu ",	" back to u, " ) { break }
			if substitute( string, " btw ",	" by the way " ) { break }
			if substitute( string, " brk ",	" break. " ) { break }
		case A( "c" ), A( "C" ):
			if substitute( string, " cul ",	" see you later, " ) { break }
			if substitute( string, " cpy",	" copy " ) { break }
			if substitute( string, " cpy?",	" copy " ) { break }
			if substitute( string, " copy?",	" copy " ) { break }
			if substitute( string, " cuagn ",	" see you again " ) { break }
			if substitute( string, " cocoamodem ",	" cocoa modem " ) { break }
		case A( "d" ), A( "D" ):
			if substitute( string, " de ",		" from " ) { break }
			if substitute( string, " dwn ",		" down " ) { break }
			if substitute( string, " op ",		" operator " ) { break }
			if substitute( string, " deg ",		" degrees. " ) { break }
			if substitute( string, " degs ",		" degrees. " ) { break }
			if substitute( string, " db ",		" decibel. " ) { break }
			if substitute( string, " didnt ",	" didn't " ) { break }
			if substitute( string, " doesnt ",	" doesn't " ) { break }
			if substitute( string, " digital ",	" digital " ) { break }
			if substitute( string, " digi",		" digi-" ) { break }
		case A( "e" ), A( "E" ):
			if substitute( string, " eqsl(ag) ",		" e q s l, " ) { break }
			if substitute( string, " eqsl ",			" e q s l, " ) { break }
			if substitute( string, " elecraft ",		" ell-le-craft, " ) { break }
		case A( "f" ), A( "F" ):
			if substitute( string, " freq ",	" frequency " ) { break }
			if substitute( string, " fldigi ", " F L digi " ) { break }
			if substitute( string, " fldigi.", " F L digi " ) { break }
		case A( "g" ), A( "G" ):
			if substitute( string, " gl ",	" good luck " ) { break }
		case A( "h" ), A( "H" ):
			if substitute( string, " how ",	" how " ) { break }
			if substitute( string, " hw.",	" how. " ) { break }
			if substitute( string, " hw ",	" how " ) { break }
			if substitute( string, " hr ",	" here " ) { break }
			if substitute( string, " hw?",	" how copy " ) { break }
		case A( "i" ), A( "I" ):
			if substitute( string, " icom ",	" eye com " ) { break }
			if substitute( string, " imd ",	" eye emm dee " ) { break }
		case A( "k" ), A( "K" ):
			if substitute( string, " k ",		" go ahead. " ) { break }
			if substitute( string, " kk ",		" go ahead. " ) { break }
			if substitute( string, " kkk ",		" go ahead. " ) { break }
			if substitute( string, " kkkk ",		" go ahead. " ) { break }
			if substitute( string, " kn ",	" go ahead. " ) { break }
			if substitute( string, " kt ",	" knots " ) { break }
			if substitute( string, " kt.",	" knots " ) { break }
		case A( "l" ), A( "L" ):
			if substitute( string, " loc ",	" locator " ) { break }
			if substitute( string, " lotw ",	" logbook of the world. " ) { break }
		case A( "m" ), A( "M" ):
			if substitute( string, " mtr ",	" meters " ) { break }
		case A( "n" ), A( "N" ):
			if substitute( string, " nnnn ",	" end of message. " ) { break }
			if substitute( string, " nr?",	" number? " ) { break }
		case A( "o" ), A( "O" ):
			if substitute( string, " OM ",	" O M, " ) { break }
			if substitute( string, " OSX ",	" OS Ten " ) { break }
		case A( "p" ), A( "P" ):
			if substitute( string, " pse ",	" please " ) { break }
			if substitute( string, " pls ",	" please " ) { break }
			if substitute( string, " pwr ",	" power " ) { break }
		case A( "q" ), A( "Q" ):
			if substitute( string, " qrz.com ",	" Q R Zed dot com. " ) { break }
			if substitute( string, " qrz",	" Q R Zed " ) { break }
			if substitute( string, " qso ",	" Q S Oh " ) { break }
		case A( "r" ), A( "R" ):
			substitute( string, " rpt ",		" report " )
			substitute( string, " rsq ",		" R S Q " )
			substitute( string, " rtty ",		" re-tee " )
			substitute( string, " rigblaster ", " rig blaster " )
		case A( "s" ), A( "S" ):
			if substitute( string, " sk ",	" signing off " ) { break }
			if substitute( string, " sase ",	" S A S E " ) { break }
			if substitute( string, " sri ",	" sorry " ) { break }
			if substitute( string, " sry ",	" sorry " ) { break }
			if substitute( string, " stdby ", " standby " ) { break }
		case A( "t" ), A( "T" ):
			if substitute( string, " tnx ",	" thanks " ) { break }
			if substitute( string, " tu ",	" thank you " ) { break }
		case A( "u" ), A( "U" ):
			substitute( string, " ur ",	" your, " )
		case A( "v" ), A( "V" ):
			substitute( string, " vfo ",	" V-F-oh " )
		case A( "w" ), A( "W" ):
			if substitute( string, " wx. ",		" weather. " ) { break }
			if substitute( string, " wx ",		" weather " ) { break }
			if substitute( string, " windom ",	" wind dom " ) { break }
			if substitute( string, " windoze ",	" windows " ) { break }
		case A( "x" ), A( "X" ):
			substitute( string, " xmit ",	" transmit " )
		case A( "y" ), A( "Y" ):
			if substitute( string, " yaesu ",	" yea sue " ) { break }
			if substitute( string, " yrs ",		" years " ) { break }
			if substitute( string, " yeasu ",	" yea sue " ) { break }
		case A( "z" ), A( "Z" ):
			substitute( string, " zczc ",	" begin of message. " )
		case A( "." ):
			substitute( string, ". /",		" ,slash " )
		case A( "@" ):
			substitute( string, "@",		" ,at " )
		case A( ":" ):
			substitute( string, "@",		" ,colon " )
		case A( "+" ):
			substitute( string, "+",		" plus " )
		case A( "/" ):
			substitute( string, "/",		". slash " )
		case A( "-" ):
			substitute( string, " - ",		"  " )
		case A( "?" ):
			substitute( string, "?",		" " )
		default:
			break
		}
		// NSLog( ... )

		return false
	}

	@objc func addToVoice( _ asciiIn: Int32 )
	{
		var ascii = asciiIn
		var length: Int

		if enabled == false || muted { return }

		if ascii == 0xd8 || ascii == 0xf8 {
			ascii = A( "0" )
		} else if ascii == 8 {
			//  backspace
			length = buffer[producer].length
			if length > 0 {
				buffer[producer].deleteCharacters( in: NSMakeRange( length-1, 1 ) )
				return
			}
		}

		if useSpell {
			spell( ascii )
			return
		}
		if ascii == A( "=" ) || ascii == A( "_" ) { return }

		if ascii == A( "\t" ) || ascii == A( ":" ) || ascii == A( "(" ) || ascii == A( ")" ) { ascii = A( " " ) }
		if ascii == A( "\n" ) || ascii == A( "\r" ) { ascii = A( "," ) }

		if deferredDot && !( ascii == A( "c" ) || ascii == A( "C" ) ) {
			deferredDot = false
			expand( buffer[producer] )
			producer = ( producer+1 ) % kVoiceBuffers
			buffer[producer].setString( " " )
			buffer[producer].append( String( format: "%c", ascii ) )
			needsSound = true
			return
		}
		deferredDot = false

		if buffer[producer].length > 15 {
			buffer[producer].setString( " " )
			return
		}

		if isStringBreak( ascii ) {
			if buffer[producer].length > 1 {
				switch ascii {
				case A( "\n" ), A( "\r" ), A( " " ):
					buffer[producer].append( " " )
					expand( buffer[producer] )
					producer = ( producer+1 ) % kVoiceBuffers
					buffer[producer].setString( " " )
				case A( "?" ):
					buffer[producer].append( "?" )
					expand( buffer[producer] )
					producer = ( producer+1 ) % kVoiceBuffers
					buffer[producer].setString( " " )
				case A( "." ):
					buffer[producer].append( "." )
					deferredDot = true
				case A( "/" ):
					buffer[producer].append( " " )
					expand( buffer[producer] )
					producer = ( producer+1 ) % kVoiceBuffers
					buffer[producer].setString( " . / " )
					expand( buffer[producer] )
					producer = ( producer+1 ) % kVoiceBuffers
					buffer[producer].setString( " " )
				default:
					buffer[producer].append( String( format: " %c", ascii ) )
					expand( buffer[producer] )
					producer = ( producer+1 ) % kVoiceBuffers
					buffer[producer].setString( " " )
				}
				needsSound = true
			}
		} else {
			buffer[producer].append( String( format: "%c", ascii ) )
		}
	}

	@objc func speechSynthesizer( _ sender: NSSpeechSynthesizer, didFinishSpeaking success: Bool )
	{
		if producer != consumer && success == true {
			needsSound = true
		}
	}

	@objc func clearVoice()
	{
		synth.stopSpeaking()
		for i in 0..<kVoiceBuffers { buffer[i].setString( " " ) }
		deferredDot = false
		producer = 0
		consumer = 0
	}

	@objc func setRate( _ rate: Float )
	{
		//  NSSpeechSynthesizer setRate does not work with 10.4uSDK
	}
}
