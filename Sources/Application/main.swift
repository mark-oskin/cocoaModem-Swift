//
//  main.swift
//  cocoaModem
//
//  Created by Kok Chen on Wed May 12 2004.
//  Swift port of main.m.
//
//  Defines the global `int vuSegmentTable[1416]` (declared extern in
//  Includes/modemTypes.h) as a Swift module-level global, and performs app
//  startup via NSApplicationMain.
//
//  The various compile-time test harnesses in the original main.m
//  (TESTBAUDOT / CERR / QPSKTABLE / TESTIIRDESIGN) were guarded by #ifdefs that
//  are never defined in the shipping build, so they are intentionally omitted.
//

import Cocoa
import CoreAudio

//  (The old C global `int vuSegmentTable[1416]` is now a file-private global in
//  VUMeter.swift, its only consumer — no module-level definition is needed here.)

AudioHardwareUnload()
//  use the current thread as the CoreAudio HAL's run loop
//  CFRunLoopRef runLoop = CFRunLoopGetCurrent() ;
//  AudioHardwareSetProperty( kAudioHardwarePropertyRunLoop, sizeof(CFRunLoopRef), &runLoop ) ;

exit(NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv))
