//
//  Application.swift
//  cocoaModem
//
//  Created by Kok Chen on Sun May 16 2004.
//
//  Swift port of Application.m.  This is the central controller: it owns the
//  StdManager/interfaces, the modem clocks, the AppleScript delegate glue, the
//  speech engines and the main menu actions.  It is the top level object of
//  MainMenu.nib and the target of most menu items.
//

import Cocoa

//  --- Plist keys (defined in Plist.h, which is not in the bridging header) ---
private let kAppearancePrefs    = "Appearance Prefs"
private let kEnableNetAudio     = "Use NetAudio"
private let kHideWindow         = "Hide Lite window at launch"
private let kNoOpenRouter       = "Don't open Router"
private let kVoiceAssist        = "Voice Assist"
private let kNetInputServices   = "NetAudio Input Services"
private let kNetInputAddresses  = "NetAudio Input IP"
private let kNetInputPorts      = "NetAudio Input Ports"
private let kNetInputPasswords  = "NetAudio Input Passwords"
private let kNetOutputServices  = "NetAudio Output Services"

//  Informal access to still-Objective-C collaborators that are not in the
//  bridging header (resolved dynamically through AnyObject message dispatch,
//  the same pattern used by AMConfig.swift / QSO.swift).
@objc private protocol AuralMonitorInformal {
	func showWindow()
	func unconditionalStop()
}
@objc private protocol LiteRTTYInformal {
	func showControlWindow(_ state: Bool)
}

@objc(Application)
class Application: NSResponder {

	//  --- globals (were C globals in Application.m) ---
	//  gSplashShowing is read by ModemManager.m via +[Application splashShowing]
	@objc static var splashShowing: Bool = false
	static var finishedInitialization: Bool = false
	static var mainThread: Thread?

	//  --- IBOutlets (wired by MainMenu.nib via KVC) ---
	@objc var stdManager: StdManager!
	@objc var quitMenu: NSMenuItem!
	@objc var macroTableWindow: AnyObject?

	@objc var resumeMenuItem: NSMenuItem!
	@objc var newMenuItem: NSMenuItem!
	@objc var recentMenuItem: NSMenuItem!

	@objc var qsoInterfaceEnableItem: NSMenuItem!
	@objc var qsoInterfaceItem: NSMenuItem!
	@objc var contestInterfaceItem: NSMenuItem!

	@objc var psk31RawInterfaceItem: NSMenuItem!
	@objc var psk31UnicodeInterfaceItem: NSMenuItem!

	@objc var voiceAssistMenuItem: NSMenuItem!					//  v1.01b
	@objc var directFrequencyAccessField: NSTextField!			//  v1.02b

	//  --- state ---
	private var splashScreen: splash!
	private var sleepManager: ModemSleepManager!

	private var config: Config!
	private var userInfo: UserInfo!

	//  local host IP	v0.47	(char localHostIP[32])
	private let localHostIPBuffer = Application.zeroedCChars( 32 )

	private var digitalInterfacesObj: DigitalInterfaces!		//  v0.89
	private var fskHubObj: FSKHub!								//  shared FSK hub

	private var macroScriptsObj: MacroScripts!					//  v0.89

	//  v0.70 unicode support (unsigned char [65536*2] each)
	private let jisToUnicode = Application.zeroedBytes( 65536*2 )
	private let unicodeToJis = Application.zeroedBytes( 65536*2 )
	//  v0.71
	private var allowShiftJIS = false

	//  v0.78 common aural monitor and AudioManager
	private var auralMonitorObj: AnyObject!						//  AuralMonitor (still ObjC)
	private var audioManagerObj: AudioManager!

	//  About panel
	private var about: About!
	//  AppleScript
	private var appleScript: AppDelegate!

	//  call/name selection
	private var selectedTextView: NSTextView?
	private let selectedString = Application.zeroedCChars( 34 )	//  word clicked from exchange views

	private var contestMode = false
	private var lastModifierFlags: UInt32 = 0

	//  cocoaModem time ticks
	private var utc: UTC!
	private var minute: Int32 = 0

	//	v0.96d text to speech
	private var mainReceiverVoice: Speech!
	private var subReceiverVoice: Speech!
	private var transmitterVoice: Speech!

	//	v1.01b
	private var voiceAssistFlag = false
	private var assistVoice: Speech!
	//	v1.02b
	private var speakAssistInfo: String?

	//  --- C buffer helpers ---
	private static func zeroedCChars( _ n: Int ) -> UnsafeMutablePointer<CChar> {
		let p = UnsafeMutablePointer<CChar>.allocate( capacity: n )
		p.initialize( repeating: 0, count: n )
		return p
	}
	private static func zeroedBytes( _ n: Int ) -> UnsafeMutablePointer<UInt8> {
		let p = UnsafeMutablePointer<UInt8>.allocate( capacity: n )
		p.initialize( repeating: 0, count: n )
		return p
	}

	//  mirror C's (int) truncation without trapping (see DisplayColor.cInt)
	private func cInt( _ x: Float ) -> Int32 {
		if x.isNaN { return 0 }
		if x >= 2147483647.0 { return Int32.max }
		if x <= -2147483648.0 { return Int32.min }
		return Int32( x )		//  truncates toward zero
	}

	deinit {
		localHostIPBuffer.deallocate()
		jisToUnicode.deallocate()
		unicodeToJis.deallocate()
		selectedString.deallocate()
	}

	@objc func appLevel() -> Int32
	{
		return 0
	}

	//  check if option/control/shift keys have changed
	//  send to current active modem
	@objc func modifierKeyCheck( _ notify: Notification )
	{
		guard let event = notify.object as? NSEvent else { return }
		let mask = NSEvent.ModifierFlags( [ .option, .shift, .control ] ).rawValue
		let flags = UInt32( truncatingIfNeeded: event.modifierFlags.rawValue & mask )

		if flags != lastModifierFlags {
			//  notify others of control key change (for callsign capture, etc)
			lastModifierFlags = flags
			NotificationCenter.default.post( name: NSNotification.Name( "ModifierFlagsChanged" ), object: self )
		}
	}

	@objc func keyboardModifierFlags() -> UInt32
	{
		return lastModifierFlags
	}

	//  Note: for Tiger, ( floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_3 )
	@objc func OSVersion() -> Float
	{
		return Float( NSAppKitVersion.current.rawValue )
	}

	//  command key equivalents for macro keys
	//  send to current active modem
	@objc func macroKeyCheck( _ notify: Notification )
	{
		guard let event = notify.object as? NSEvent else { return }
		if ( event.characters?.count ?? 0 ) <= 0 { return }			// v0.35

		let key = Int( ( event.charactersIgnoringModifiers as NSString? )?.character( at: 0 ) ?? 0 )

		var index: Int32
		if key >= 0x31 && key <= 0x39 { index = Int32( key - 0x31 ) }		//  '1'..'9'
		else if key == 0x30 { index = 9 }									//  '0'
		else if key == 0x2d { index = 10 }									//  '-'
		else if key == 0x3d { index = 11 }									//  '='
		else { return }

		let flags = event.modifierFlags
		let option = flags.contains( .option )
		let shift = flags.contains( .shift )

		var sheet: Int32 = 0
		if option {
			sheet = shift ? 2 : 1
		}

		guard let current = stdManager.currentModem() else { return }
		if contestMode {
			//  ask contestManager to execute (common) contest macro
			stdManager.executeContestMacro( fromShortcut: index, sheet: sheet, modem: current as? ContestInterface )
		}
		else {
			//  ask modem to execute macro
			( current as? ContestInterface )?.executeMacro( index, sheetNumber: sheet )
		}
	}

	@objc func sysBeep( _ notify: Notification )
	{
	}

	@objc func clock() -> UTC!
	{
		return utc
	}

	//  internal UTC clock server
	@objc func tick( _ timer: Timer? )
	{
		let time = utc.setTime()
		NotificationCenter.default.post( name: NSNotification.Name( "SecondTick" ), object: utc )

		if minute != time.pointee.tm_min {
			minute = time.pointee.tm_min
			NotificationCenter.default.post( name: NSNotification.Name( "MinuteTick" ), object: utc )
		}
	}

	/* local */
	private func getLocalHostIP()
	{
		strcpy( localHostIPBuffer, "127.0.0.1" )
		for address in Host.current().addresses {
			if address.contains( "." ) {					//  IPv4 dotted quad
				address.withCString { _ = strcpy( localHostIPBuffer, $0 ) }
				return
			}
		}
	}

	/* local */
	private func createNetInputPorts( _ pref: Preferences ) -> [NetAudio]
	{
		var array: [NetAudio] = []
		let serviceArray = pref.array( forKey: kNetInputServices )
		let ipArray = pref.array( forKey: kNetInputAddresses )
		let portArray = pref.array( forKey: kNetInputPorts )
		let passwordArray = pref.array( forKey: kNetInputPasswords )

		//  v0.64d use NetAudio only if in Preferences
		if pref.hasKey( kEnableNetAudio ) == false { return array }
		if pref.intValue( forKey: kEnableNetAudio ) == 0 { return array }

		//  sanity check
		guard let serviceArray = serviceArray, serviceArray.count >= 4 else { return array }
		guard let ipArray = ipArray, ipArray.count > 0 else { return array }
		guard let portArray = portArray, portArray.count > 0 else { return array }

		for i in 0..<4 {
			var netAudio: NetAudio? = nil
			let service = serviceArray[i] as? String

			//  check if service name, IP address or port number is specified
			if let service = service, service.isEmpty == false {
				netAudio = NetReceive( service: service, delegate: nil, samplesPerBuffer: 512 )
			}
			else {
				let ip = ( i < ipArray.count ) ? ( ipArray[i] as? String ) : nil
				let portNum = ( i < portArray.count ) ? ( portArray[i] as? String ) : nil
				if ( ip != nil && ip!.isEmpty == false ) || ( portNum != nil && portNum!.isEmpty == false ) {
					let port: Int32 = ( portNum != nil && portNum!.isEmpty == false ) ? ( portNum! as NSString ).intValue : 52800
					if let ip = ip, ip.isEmpty == false {
						netAudio = ip.withCString { NetReceive( address: $0, port: port, delegate: nil, samplesPerBuffer: 512 ) }
					}
					else {
						if localHostIPBuffer[0] == 0 { getLocalHostIP() }
						netAudio = NetReceive( address: UnsafePointer( localHostIPBuffer ), port: port, delegate: nil, samplesPerBuffer: 512 )
					}
				}
			}
			if let netAudio = netAudio {
				let password = ( passwordArray != nil && i < passwordArray!.count ) ? ( passwordArray![i] as? String ) : nil
				if let password = password, password.isEmpty == false { _ = netAudio.setPassword( password ) }
				array.append( netAudio )
			}
		}
		return array
	}

	private func createNetPorts( _ pref: Preferences, isInput: Bool ) -> [NetAudio]
	{
		var array: [NetAudio] = []
		guard let prefArray = pref.array( forKey: isInput ? kNetInputServices : kNetOutputServices ) else { return array }

		let count = prefArray.count
		for j in 0..<count {
			var netAudio: NetAudio? = nil
			guard let str0 = prefArray[j] as? String, str0.isEmpty == false else { continue }

			if isInput {
				//  NetReceive, either an ip1.ip2.ip3.ip4:port quad or a service name
				var parsed = false
				if let colon = str0.firstIndex( of: ":" ) {
					let host = String( str0[..<colon] )
					let portStr = String( str0[str0.index( after: colon )...] )
					let octets = host.split( separator: ".", omittingEmptySubsequences: false )
					if octets.count == 4, let port = Int32( portStr ), port >= 0,
					   octets.allSatisfy( { if let v = Int32( $0 ), v >= 0 { return true }; return false } ) {
						//  get NetReceive with ip:port
						netAudio = host.withCString { NetReceive( address: $0, port: port, delegate: nil, samplesPerBuffer: 512 ) }
						parsed = true
					}
				}
				if parsed == false {
					//  get NetReceive using service name
					netAudio = NetReceive( service: str0, delegate: nil, samplesPerBuffer: 512 )
				}
			}
			else {
				//  NetSend, either service name, or servicename:port
				var service = str0
				var port: Int32 = -1
				if let colon = str0.firstIndex( of: ":" ) {
					service = String( str0[..<colon] )
					if let p = Int32( str0[str0.index( after: colon )...] ), p >= 0 { port = p }
				}
				netAudio = NetSend( service: service, delegate: nil, samplesPerBuffer: 512 )
				if port >= 0, let na = netAudio as? NetSend {
					//  try setting the port number
					if na.setPortNumber( port ) == false { netAudio = nil }
				}
			}
			if let netAudio = netAudio { array.append( netAudio ) }
		}
		return array
	}

	@objc func localHostIP() -> UnsafePointer<CChar>!
	{
		if localHostIPBuffer[0] == 0 { getLocalHostIP() }		// v0.53b deferred getLocalIP
		return UnsafePointer( localHostIPBuffer )
	}

	//  v0.71
	@objc(setAllowShiftJISForPSK:)
	func setAllowShiftJISForPSK( _ state: Bool )
	{
		allowShiftJIS = state
		if state == false {
			//  if preference is not set, check if we are Japanese Mac OS X
			let n = ( NSLocalizedString( "Use Shift-JIS", comment: "" ) as NSString ).character( at: 0 )
			if n != 0x31 {			//  '1'
				psk31UnicodeInterfaceItem?.keyEquivalent = ""
				return
			}
		}
		//  preference sets allow shift-JIS
		psk31UnicodeInterfaceItem?.keyEquivalent = "j"
	}

	//	v1.02c
	@objc func updateDirectAccessFrequency()
	{
		let freq = stdManager.selectedFrequency()
		directFrequencyAccessField?.floatValue = freq
	}

	//  v1.02e
	@objc(setSpeakAssistInfo:)
	func setSpeakAssistInfo( _ string: String? )
	{
		speakAssistInfo = string.map { String( $0 ) }
	}

	@objc func speakAlertInfo( _ sender: Any? )
	{
		guard let info = speakAssistInfo else {
			speakAssist( "No alert info." )
			return
		}
		speakAssist( info )
	}

	override func awakeFromNib()
	{
		//	v1.01b
		voiceAssistFlag = false
		//	v1.02d
		assistVoice = Speech( voice: nil )
		assistVoice.setVerbatim( true )
		assistVoice.setMute( false )
		assistVoice.setSpell( false )
		//	v1.02e
		speakAssistInfo = nil

		//  v0.96d
		mainReceiverVoice = Speech( voice: nil )
		subReceiverVoice = Speech( voice: nil )
		transmitterVoice = Speech( voice: nil )

		//  v0.78
		auralMonitorObj = nil
		audioManagerObj = nil
		initAudioUtils()

		//  set up local IP defer until needed
		localHostIPBuffer[0] = 0

		Application.mainThread = Thread.current

		splashScreen = splash()
		showSplash( "Welcome" )

		//  v0.70 read Shift-JIS Tables from resource
		allowShiftJIS = false
		for i in 0..<65536 { jisToUnicode[i] = 0; unicodeToJis[i] = 0 }
		let bundle = Bundle.main
		let jisPath = bundle.bundlePath + "/Contents/Resources/jisToUni.dat"
		if let jisdata = NSData( contentsOfFile: jisPath ) { memcpy( jisToUnicode, jisdata.bytes, 65536*2 ) }
		let uniPath = bundle.bundlePath + "/Contents/Resources/uniToJis.dat"
		if let unidata = NSData( contentsOfFile: uniPath ) {
			memcpy( unicodeToJis, unidata.bytes, 65536*2 )
			//  v0.81 Shift-JIS slashed zero
			unicodeToJis[216*2] = 0
			unicodeToJis[216*2+1] = 216
		}

		//  initialize CoreModem framework
		_ = ( NSClassFromString( "CoreModem" ) as? NSObject.Type )?.init()

		contestMode = false

		//	v1.02b
		directFrequencyAccessField?.target = self
		directFrequencyAccessField?.action = #selector( directFrequencyAccessed(_:) )

		//  v0.70
		psk31UnicodeInterfaceItem?.target = self
		psk31UnicodeInterfaceItem?.action = #selector( useUnicodeForPSKChanged(_:) )
		psk31RawInterfaceItem?.target = self
		psk31RawInterfaceItem?.action = #selector( useRawForPSKChanged(_:) )

		//  accepts SysBeep messages here
		NotificationCenter.default.addObserver( self, selector: #selector( sysBeep(_:) ), name: NSNotification.Name( "SysBeep" ), object: nil )
		//  create sleep manager
		sleepManager = ModemSleepManager( application: self )

		selectedString[0] = 0
		selectedTextView = nil
		splashScreen.positionWindow()
		Application.splashShowing = true

		//  check Plist (temporary copy) to see which UI and if we should search for NetAudio devices
		let tempPref = Preferences()
		tempPref.fetchPlist( false )

		let dontOpenRouter = tempPref.intValue( forKey: kNoOpenRouter ) != 0

		//	v0.89  Digital Interfaces
		if dontOpenRouter {
			digitalInterfacesObj = DigitalInterfaces( withoutRouter: true )
		}
		else {
			digitalInterfacesObj = DigitalInterfaces()
		}
		macroScriptsObj = MacroScripts()						//  v0.89

		var isBrushedMetal = false
		var isLite = false

		if let prefString = tempPref.stringValue( forKey: kAppearancePrefs ) {		// v0.42
			prefString.withCString { s in
				let n = strlen( s )
				if n >= 9 && s[8] == 0x31 { isLite = true }		//  '1'
				else { isBrushedMetal = ( n < 6 || s[5] == 0x31 ) }
			}
		}
		//  v0.64d
		var useNetAudio = false
		if tempPref.hasKey( kEnableNetAudio ) {
			if tempPref.intValue( forKey: kEnableNetAudio ) != 0 { useNetAudio = true }
		}
		if useNetAudio {
			//  v0.47
			_ = createNetInputPorts( tempPref )
			_ = createNetPorts( tempPref, isInput: false )
		}

		//  v0.76s release thread for 60 ms to allow other things to run
		Thread.sleep( until: Date( timeIntervalSinceNow: 0.06 ) )

		//  v0.50 shared FSKHub
		fskHubObj = FSKHub()
		//  create UserInfo (must be before StdManager setupWindow)
		userInfo = UserInfo()

		//  v0.78 aural monitor and AudioManager
		audioManagerObj = AudioManager()
		auralMonitorObj = ( NSClassFromString( "AuralMonitor" ) as? NSObject.Type )?.init()

		//  select UI (must be set up before modems)
		stdManager.setupWindow( isBrushedMetal, lite: isLite )

		stdManager.useSmoothPattern( true )
		stdManager.updateQSOWindow()

		//  don't allocate About panel until needed
		about = nil
		showSplash( "Discover Audio Devices" )

		//  configure from Preference
		showSplash( "Creating User Configuration" )

		config = Config( app: self )
		config.awakeFromApplication()

		//  create the modems based on what is asked for in the Preference panel
		stdManager.createModems( config, startModemsFromPlist: tempPref )

		//  v0.53b
		Application.finishedInitialization = true

		//  AppleScript support
		appleScript = AppDelegate( fromApplication: self )

		appleScript.setIsLite( isLite )

		//  set up default preferences in case Plist does not exist
		showSplash( "Reading preferences" )
		config.setupDefaultPreferences()

		//  now update preferences from the Plist file, if file exists
		config.fetchPlist( true )

		//  then, update preferences from Plist file
		showSplash( "Updating preferences" )
		_ = config.updatePreferences()

		//  now make window visible and set us as delegate
		let window = stdManager.windowObject()
		if isLite {
			//  check if we want to keep a Lite window hidden anyway
			if config.intValue( forKey: kHideWindow ) == 0 {
				window?.orderFront( self )
				( stdManager.wfRTTYModem() as AnyObject ).showControlWindow?( true )
				appleScript.setWindowIsVisible( true )
			}
			else {
				( stdManager.wfRTTYModem() as AnyObject ).showControlWindow?( false )
				appleScript.setWindowIsVisible( false )
			}
		}
		else {
			window?.orderFront( self )
			appleScript.setWindowIsVisible( true )
		}

		window?.makeFirstResponder( self )

		//  add notification observer for option key
		lastModifierFlags = 0
		NotificationCenter.default.addObserver( self, selector: #selector( modifierKeyCheck(_:) ), name: NSNotification.Name( "OptionKey" ), object: nil )
		NotificationCenter.default.addObserver( self, selector: #selector( macroKeyCheck(_:) ), name: NSNotification.Name( "MacroKeyboardShortcut" ), object: nil )

		//  set up cocoaModem timer
		utc = UTC()
		minute = -1
		Timer.scheduledTimer( timeInterval: 1.0, target: self, selector: #selector( tick(_:) ), userInfo: self, repeats: true )

		//  start off by selecting the interactive interface
		switchInterfaceMode( 0 )

		splashScreen.remove()
		Application.splashShowing = false

		if config.booleanValue( forKey: kVoiceAssist ) {
			toggleVoiceAssist( voiceAssistMenuItem )			//  v1.01b
			stdManager.speakModemSelection()					//  v1.02c
			speakAssist( " , " )
			updateDirectAccessFrequency()						//  v1.02c
		}
	}

	@objc func mainWindow() -> NSWindow!
	{
		return stdManager.windowObject()
	}

	//  v0.50
	@objc func fskHub() -> FSKHub!
	{
		return fskHubObj
	}

	@objc func stdManagerObject() -> StdManager!
	{
		return stdManager
	}

	@objc func userInfoObject() -> UserInfo!
	{
		return userInfo
	}

	@objc func auralMonitor() -> AnyObject!
	{
		return auralMonitorObj
	}

	@objc func audioManager() -> AudioManager!
	{
		return audioManagerObj
	}

	@objc func qsoEnableItem() -> NSMenuItem!
	{
		return qsoInterfaceEnableItem
	}

	//  display message on splash screen
	@objc(showSplash:)
	func showSplash( _ msg: String )
	{
		splashScreen.showMessage( NSLocalizedString( msg, comment: "" ) )		// v0.39, v0.70
	}

	@objc @discardableResult
	func speakAssist( _ assist: String ) -> Bool
	{
		if voiceAssist() {
			assistVoice.queuedSpeak( assist )
			return true
		}
		return false
	}

	@objc func flushSpeakAssist()
	{
		assistVoice.clearVoice()
	}

	@objc func showPreferences( _ sender: Any? )
	{
		config.showPreferencePanel( self )
	}

	@objc func showQSO( _ sender: Any? )
	{
		stdManager.toggleQSOShowing()
	}

	//  v1.01a
	@objc func selectQSOCall( _ sender: Any? )
	{
		stdManager.selectQSOCall()
		speakAssist( "call sign" )
	}

	//  v1.01a
	@objc func selectQSOName( _ sender: Any? )
	{
		stdManager.selectQSOName()
		speakAssist( "name" )
	}

	//  v1.01b
	@objc func toggleVoiceAssist( _ sender: Any? )
	{
		let item = sender as? NSMenuItem
		voiceAssistFlag = ( ( item?.state ?? .off ) == .off )
		item?.state = voiceAssistFlag ? .on : .off
		if voiceAssistFlag {
			assistVoice.setVoiceEnable( true )
			assistVoice.speak( "Voice Assist On." )
		}
		else {
			assistVoice.speak( "Voice Assist Offff." )
			assistVoice.setVoiceEnable( false )
		}
	}

	//  update appearance from "General" preferences
	@objc(setAppearancePrefs:)
	func setAppearancePrefs( _ appearancePrefs: NSMatrix )
	{
		let count = appearancePrefs.numberOfRows
		for i in 0..<count {
			let state = appearancePrefs.cell( atRow: i, column: 0 )?.state ?? .off
			if state == .on {
				switch i {
				case 0:
					//  enable command Q
					quitMenu?.keyEquivalent = "q"
				default:
					break
				}
			}
			else {
				switch i {
				case 0:
					//  disable command Q
					quitMenu?.keyEquivalent = ""
				default:
					break
				}
			}
		}
	}

	/* local */
	private func enableContestMenus( _ state: Bool )
	{
		resumeMenuItem?.isEnabled = state
		newMenuItem?.isEnabled = state
		recentMenuItem?.isEnabled = state
	}

	//  mode 0 - QSO mode, 1 = Contest mode
	@objc(switchInterfaceMode:)
	func switchInterfaceMode( _ mode: Int32 )
	{
		contestInterfaceItem?.state = ( mode == 1 ) ? .on : .off
		qsoInterfaceItem?.state = ( mode == 0 ) ? .on : .off

		stdManager.activateModems( true )
		enableContestMenus( true )

		stdManager.useContestMode( mode == 1 )

		contestMode = ( mode == 1 )
		stdManager.updateQSOWindow()

		//  close any open config if interface changed
		closeConfigPanels()
	}

	@objc func contestModeState() -> Bool
	{
		return contestMode
	}

	//  v0.70
	@objc(saveSelectedString:view:)
	func saveSelectedString( _ string: String, view: NSTextView )
	{
		selectedTextView = view
		let ns = string as NSString
		var length = ns.length
		if length > 32 { length = 32 }
		for i in 0..<length {
			let u = ns.character( at: i )
			selectedString[i] = CChar( truncatingIfNeeded: Int( u ) & 0xff )		//  only allow ASCII
		}
		selectedString[length] = 0
	}

	//  ask all interfaces to close their config panels
	@objc func closeConfigPanels()
	{
		stdManager.closeConfigPanels()
	}

	//  show config window of current mode of current interface
	@objc func showConfig( _ sender: Any? )
	{
		stdManager.showConfigPanel()
	}

	@objc func showSoftRock( _ sender: Any? )
	{
		stdManager.showSoftRock()
	}

	//  show About panel, allocate and load Nib file if needed
	@objc func showAboutPanel( _ sender: Any? )
	{
		if about == nil { about = About().initFromNib() }
		about.showPanel()
	}

	//	v1.02b
	@objc func showDirectFrequencyAccess( _ sender: Any? )
	{
		directFrequencyAccessField?.window?.makeKeyAndOrderFront( self )
	}

	//	v1.02b
	@objc func directFrequencyAccess( _ sender: Any? )
	{
		updateDirectAccessFrequency()
		directFrequencyAccessField?.window?.makeKeyAndOrderFront( self )
		directFrequencyAccessField?.selectText( self )
		speakAssist( " Enter frequency - ending with a carriage return. " )
	}

	@objc func speakContentsOfCurrentFrequency()
	{
		let freq = directFrequencyAccessField?.floatValue ?? 0

		if freq < 1 {
			speakAssist( " Modem turned off. " )
			return
		}
		let ifreq = cInt( freq )
		if fabs( Double( ifreq ) - Double( freq ) ) < 0.05 {
			flushSpeakAssist()
			speakAssist( String( format: "Tuned to %d Hertz ", ifreq ) )
		}
		else {
			flushSpeakAssist()
			speakAssist( String( format: "Tuned to %.1f Hertz ", freq ) )
		}
	}

	@objc func speakCurrentFrequency( _ sender: Any? )
	{
		speakContentsOfCurrentFrequency()
	}

	//	v1.02c
	@objc func selectNextModem( _ sender: Any? )
	{
		stdManager.selectNextModem()
	}

	//	v1.02c
	@objc func selectPreviousModem( _ sender: Any? )
	{
		stdManager.selectPreviousModem()
	}

	@objc func showRTTYScope( _ sender: Any? )
	{
		stdManager.displayRTTYScope()
	}

	@objc func showAuralMonitor( _ sender: Any? )
	{
		auralMonitorObj?.showWindow?()
	}

	@objc func showUserInfo( _ sender: Any? )
	{
		userInfo.showSheet( stdManager.windowObject() )
	}

	//  open Cabrillo sheet in contest manager
	@objc func showContestInfo( _ sender: Any? )
	{
		stdManager.showCabrilloInfo()
	}

	@objc func switchToTransmit( _ sender: Any? )
	{
		stdManager.windowObject()?.makeKey()						// v0.33
		stdManager.switchCurrentModem( toTransmit: true )
	}

	@objc func switchToReceive( _ sender: Any? )
	{
		stdManager.switchCurrentModem( toTransmit: false )
	}

	@objc func flushToReceive( _ sender: Any? )
	{
		stdManager.flushCurrentModem()
	}

	//	v0.70  Added menu item to Interface Menu
	@objc(useUnicodeForPSKChanged:)
	func useUnicodeForPSKChanged( _ sender: Any? )
	{
		setUseUnicodeForPSK( ( psk31UnicodeInterfaceItem?.state ?? .off ) == .off )
	}

	//  v0.70
	@objc func useUnicodeForPSK() -> Bool
	{
		return ( psk31UnicodeInterfaceItem?.state ?? .off ) == .on
	}

	//  v0.70
	@objc(setUseUnicodeForPSK:)
	func setUseUnicodeForPSK( _ state: Bool )
	{
		//  v0.71
		if allowShiftJIS == false {
			//  if pref is not set, check if Japanese Mac OS X
			let n = ( NSLocalizedString( "Use Shift-JIS", comment: "" ) as NSString ).character( at: 0 )
			if n != 0x31 {		//  '1'
				if state == true {
					_ = runAlert( NSLocalizedString( "Shift-JIS setting ignored.", comment: "" ),
					              informative: NSLocalizedString( "Shift-JIS cannot be turned on", comment: "" ),
					              buttons: [ NSLocalizedString( "OK", comment: "" ) ] )
				}
				stdManager.setUseShiftJIS( false )
				return
			}
		}
		psk31UnicodeInterfaceItem?.state = ( state == false ) ? .off : .on
		let useShiftJIS = ( psk31UnicodeInterfaceItem?.state ?? .off ) == .on
		stdManager.setUseShiftJIS( useShiftJIS )
	}

	//  v0.70
	@objc func jisToUnicodeTable() -> UnsafeMutablePointer<UInt8>!
	{
		return jisToUnicode
	}

	//  v0.70
	@objc func unicodeToJisTable() -> UnsafeMutablePointer<UInt8>!
	{
		return unicodeToJis
	}

	//  v0.70
	@objc(setUseRawForPSK:)
	func setUseRawForPSK( _ state: Bool )
	{
		psk31RawInterfaceItem?.state = ( state == false ) ? .off : .on
		let useRaw = ( psk31RawInterfaceItem?.state ?? .off ) == .on
		stdManager.setUseRawForPSK( useRaw )
	}

	//	v0.70  Added menu item to Interface Menu
	@objc(useRawForPSKChanged:)
	func useRawForPSKChanged( _ sender: Any? )
	{
		setUseRawForPSK( ( psk31RawInterfaceItem?.state ?? .off ) == .off )
	}

	//	v1.02b
	@objc(setDirectFrequencyFieldTo:)
	func setDirectFrequencyFieldTo( _ value: Float )
	{
		let ivalue = cInt( value )
		directFrequencyAccessField?.stringValue = ( fabs( Double( ivalue ) - Double( value ) ) < 0.05 ) ? String( format: "%d", ivalue ) : String( format: "%.1f", value )
		Timer.scheduledTimer( timeInterval: 0.25, target: self, selector: #selector( speakContentsOfCurrentFrequency ), userInfo: nil, repeats: false )
	}

	//	v1.02b  Direct frequency Access
	@objc(directFrequencyAccessed:)
	func directFrequencyAccessed( _ sender: Any? )
	{
		let freq = ( sender as? NSControl )?.floatValue ?? 0
		if freq > 0 {
			if freq < 400 || freq > 2400 {
				let ifreq = cInt( stdManager.selectedFrequency() )
				if ifreq > 0 {
					( sender as? NSControl )?.stringValue = String( format: "%d", ifreq )
					speakAssist( String( format: "Frequency out of range, unchanged at %d Hertz.", ifreq ) )
				}
				else { speakAssist( "Frequency out of range " ) }
			}
			else {
				if fabs( Double( stdManager.selectedFrequency() ) - Double( freq ) ) < 0.1 {
					let ifreq = cInt( freq )
					if fabs( Double( ifreq ) - Double( freq ) ) < 0.05 {
						speakAssist( String( format: "Frequency unchanged. Already tuned to %d Hertz.", ifreq ) )
					}
					else {
						speakAssist( String( format: "Frequency unchanged. Already tuned to %.1f Hertz.", freq ) )
					}
					return
				}
				stdManager.directSetFrequency( freq )
			}
		}
		else {
			stdManager.directSetFrequency( 0 )
		}
	}

	@objc func selectInterfaceMode( _ sender: Any? )
	{
		let mode = ( sender as? NSMenuItem )?.tag ?? 0

		//  check to see if any contest has been selected, if not, do nothing
		if mode == 1 && stdManager.currentContest() == nil { return }

		//  tag 0 - QSO mode, 1 = Contest mode
		switchInterfaceMode( Int32( mode ) )
	}

	@objc func swapInterfaceMode( _ sender: Any? )
	{
		//  check to see if any contest has been selected, if not, do nothing
		if stdManager.currentContest() == nil { return }

		switchInterfaceMode( contestMode ? 0 : 1 )
	}

	@objc func qsoCommands( _ sender: Any? )
	{
		//  check if there is a selected string
		let string = ( sender as? NSMenuItem )?.title ?? ""
		var t: Int32 = 0
		if string == "Copy Callsign" { t = 67 }			//  'C'
		else if string == "Copy Name" { t = 78 }		//  'N'

		transfer( toQSOField: t )
	}

	@objc(transferToQSOField:)
	func transfer( toQSOField t: Int32 )
	{
		if selectedString[0] == 0 { return }
		if t != 0 {
			stdManager.qsoObject()?.copyString( selectedString, into: t )
			if let view = selectedTextView {
				//  unselect the field
				view.lockFocus()
				var range = view.selectedRange()
				range.length = 0
				view.setSelectedRange( range )
				view.unlockFocus()
				selectedTextView = nil
			}
		}
	}

	@objc(enableContestMenuItems:)
	func enableContestMenuItems( _ state: Bool )
	{
		qsoInterfaceItem?.isEnabled = state
		contestInterfaceItem?.isEnabled = state
		resumeMenuItem?.isEnabled = state
		newMenuItem?.isEnabled = state
		recentMenuItem?.isEnabled = state
	}

	//  clean up and save Plist
	@objc func terminate() -> NSApplication.TerminateReply
	{
		if stdManager.okToQuit() == false {
			let reply = runAlert( NSLocalizedString( "database not saved", comment: "" ),
			                      informative: NSLocalizedString( "save contest", comment: "" ),
			                      buttons: [ NSLocalizedString( "OK", comment: "" ), NSLocalizedString( "Quit anyway", comment: "" ) ] )
			//  "Quit anyway" (the second/other button) is the only response that proceeds
			if reply != .alertSecondButtonReturn { return .terminateCancel }
		}
		stdManager.applicationTerminating()

		// v0.50
		if let hub = fskHubObj {
			hub.closeFSKConnections()
			fskHubObj = nil
		}
		if let di = digitalInterfacesObj { di.terminate( config ) }

		sleepManager = nil			// this should deallocate it

		config.setBoolean( voiceAssist(), forKey: kVoiceAssist )
		config.savePlist()

		//  v0.78
		auralMonitorObj?.unconditionalStop?()
		audioManagerObj = nil

		return .terminateNow
	}

	//  called from ModemSleepManager
	@objc func putCodecsToSleep()
	{
		audioManagerObj?.putCodecsToSleep()
	}

	//  called from ModemSleepManager
	@objc func wakeCodecsUp()
	{
		audioManagerObj?.wakeCodecsUp()
	}

	//   NSResponder - catches option and shift keys
	override func flagsChanged( with event: NSEvent )
	{
		NotificationCenter.default.post( name: NSNotification.Name( "OptionKey" ), object: event )
		super.flagsChanged( with: event )
	}

	//   NSResponder - catches command 1 through = keys
	override func performKeyEquivalent( with event: NSEvent ) -> Bool
	{
		if let chars = event.characters, chars.isEmpty == false {		// v0.35
			let n = Int( ( event.charactersIgnoringModifiers as NSString? )?.character( at: 0 ) ?? 0 )
			if ( n >= 0x30 && n <= 0x39 ) || n == 0x2d || n == 0x3d {	//  '0'..'9', '-', '='
				NotificationCenter.default.post( name: NSNotification.Name( "MacroKeyboardShortcut" ), object: event )
				return true
			}
		}
		return false
	}

	//  AppleScript support

	//  class references
	@objc func interface() -> ModemManager!
	{
		return stdManager
	}

	@objc(changeInterfaceTo:alternate:)
	func changeInterface( to which: ModemManager!, alternate state: Bool )
	{
		switchInterfaceMode( state ? 1 : 0 )
	}

	@objc func windowShouldClose( _ sender: Any? ) -> Bool
	{
		return false
	}

	//  v0.75
	@objc(openURLDoc:)
	func openURLDoc( _ url: String )
	{
		if let u = URL( string: url ) { NSWorkspace.shared.open( u ) }
	}

	//  v0.72
	@objc func checkForUpdate( _ sender: Any? )
	{
		let appName = "cocoaModem 2.0"
		//  run the original curl command (popen/pclose are unavailable in Swift, so
		//  drive it through a shell via Process/Pipe, preserving the exact command)
		let command = "curl -s -m10 -A \"Mozilla/4.0 (compatible; MSIE 5.5; Windows 98)\" \"http://www.w7ay.net/site/Downloads/updates.txt\""

		let task = Process()
		task.launchPath = "/bin/sh"
		task.arguments = [ "-c", command ]
		let pipe = Pipe()
		task.standardOutput = pipe

		do {
			try task.run()
		}
		catch {
			_ = runAlert( NSLocalizedString( "Update information error", comment: "" ),
			              informative: NSLocalizedString( "Update file not found", comment: "" ),
			              buttons: [ NSLocalizedString( "OK", comment: "" ) ] )
			return
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		task.waitUntilExit()
		let output = String( data: data, encoding: .isoLatin1 ) ?? ""
		let lines = output.components( separatedBy: "\n" )

		var handled = false
		for line in lines.prefix( 20 ) {
			if line.hasPrefix( appName ) {
				let rest = String( line.dropFirst( appName.count ) )
				let latest = Scanner( string: rest ).scanFloat() ?? 0
				let version = ( Bundle.main.object( forInfoDictionaryKey: "CFBundleVersion" ) as? String ) ?? ""
				let current = Scanner( string: version ).scanFloat() ?? 0

				if ( latest - current ) > 0.0001 {
					let alert = runAlert( NSLocalizedString( "New download available", comment: "" ),
					                      informative: String( format: NSLocalizedString( "Update available info", comment: "" ), Double( latest ) ),
					                      buttons: [ NSLocalizedString( "OK", comment: "" ), NSLocalizedString( "What's New", comment: "" ) ] )
					if alert == .alertSecondButtonReturn {
						// v0.75
						openURLDoc( "http://www.w7ay.net/site/Applications/cocoaModem/Whats%20New/index.html" )
					}
				}
				else {
					_ = runAlert( NSLocalizedString( "Up to date", comment: "" ),
					              informative: String( format: NSLocalizedString( "Up to date info", comment: "" ), Double( latest ) ),
					              buttons: [ NSLocalizedString( "OK", comment: "" ) ] )
				}
				handled = true
				break
			}
		}
		if handled == false {
			_ = runAlert( NSLocalizedString( "Update information error", comment: "" ),
			              informative: NSLocalizedString( "No update info", comment: "" ),
			              buttons: [ NSLocalizedString( "OK", comment: "" ) ] )
		}
	}

	//	v0.96c
	@objc func selectMainView( _ sender: Any? )
	{
		stdManager.selectView( 1 )
	}

	//	v0.96c
	@objc func selectSubView( _ sender: Any? )
	{
		stdManager.selectView( 2 )
	}

	//	v0.96c
	@objc func selectTransmitView( _ sender: Any? )
	{
		stdManager.selectView( 0 )
	}

	//	v0.96d
	@objc func muteSpeech( _ sender: Any? )
	{
		let item = sender as? NSMenuItem
		var state: Bool
		if ( item?.state ?? .off ) == .off {
			item?.state = .on
			state = true
		}
		else {
			item?.state = .off
			state = false
			mainReceiverVoice.speak( "Text To Speech On." )
		}
		transmitterVoice.setMute( state )
		mainReceiverVoice.setMute( state )
		subReceiverVoice.setMute( state )
	}

	//	v1.00
	@objc func spellSpeech( _ sender: Any? )
	{
		let item = sender as? NSMenuItem
		var state: Bool
		if ( item?.state ?? .off ) == .off {
			item?.state = .on
			state = true
		}
		else {
			item?.state = .off
			state = false
		}
		transmitterVoice.setSpell( state )
		mainReceiverVoice.setSpell( state )
		subReceiverVoice.setSpell( state )
	}

	@objc func digitalInterfaces() -> DigitalInterfaces!
	{
		return digitalInterfacesObj
	}

	@objc func macroScripts() -> MacroScripts!
	{
		return macroScriptsObj
	}

	//	v0.96d TextToSpeech
	//	channel 0	transmit
	//			1	main receiver
	//			2	sub receiver
	@objc(addToVoice:channel:)
	func addToVoice( _ ascii: Int32, channel: Int32 )
	{
		switch channel {
		case 0:
			transmitterVoice.addToVoice( ascii )
		case 1:
			mainReceiverVoice.addToVoice( ascii )
		case 2:
			subReceiverVoice.addToVoice( ascii )
		case 3:
			assistVoice.addToVoice( ascii )
		default:
			break
		}
	}

	@objc(setVoice:channel:)
	func setVoice( _ name: String?, channel: Int32 )
	{
		switch channel {
		case 0:
			transmitterVoice.setVoice( name )
		case 1:
			mainReceiverVoice.setVoice( name )
		case 2:
			subReceiverVoice.setVoice( name )
		case 3:
			assistVoice.setVoice( name )
			speakAssist( "Welcome to cocoaModem." )
		default:
			break
		}
	}

	@objc(setVoiceEnable:channel:)
	func setVoiceEnable( _ state: Bool, channel: Int32 )
	{
		switch channel {
		case 0:
			transmitterVoice.setVoiceEnable( state )
		case 1:
			mainReceiverVoice.setVoiceEnable( state )
		case 2:
			subReceiverVoice.setVoiceEnable( state )
		default:
			break
		}
	}

	@objc(setVerbatimSpeech:channel:)
	func setVerbatimSpeech( _ state: Bool, channel: Int32 )
	{
		switch channel {
		case 0:
			transmitterVoice.setVerbatim( state )
		case 1:
			mainReceiverVoice.setVerbatim( state )
		case 2:
			subReceiverVoice.setVerbatim( state )
		default:
			break
		}
	}

	@objc(clearVoiceChannel:)
	func clearVoiceChannel( _ channel: Int32 )
	{
		switch channel {
		case 0:
			transmitterVoice.clearVoice()
		case 1:
			mainReceiverVoice.clearVoice()
		case 2:
			subReceiverVoice.clearVoice()
		default:
			break
		}
	}

	@objc func clearAllVoices()
	{
		transmitterVoice.clearVoice()
		mainReceiverVoice.clearVoice()
		subReceiverVoice.clearVoice()
	}

	//	v1.01b
	@objc func voiceAssist() -> Bool
	{
		return voiceAssistFlag
	}

	//  --- helpers ---

	@discardableResult
	private func runAlert( _ message: String, informative: String, buttons: [String] ) -> NSApplication.ModalResponse
	{
		let alert = NSAlert()
		alert.messageText = message
		alert.informativeText = informative
		for b in buttons { alert.addButton( withTitle: b ) }
		return alert.runModal()
	}
}
