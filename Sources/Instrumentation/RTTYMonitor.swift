//
//  RTTYMonitor.swift
//  cocoaModem
//
//  Created by Kok Chen on Sat Jun 05 2004.
//
//  Swift port of RTTYMonitor.m.  RTTYMonitor remains a subclass of the
//  Objective-C DSP pipe base CMTappedPipe (CMTappedPipe stays Objective-C;
//  its header is in the bridging header).
//

import Cocoa

//  Informal, dynamically dispatched access to the Oscilloscope scope view.
//  Oscilloscope is an NSView subclass connected through the "Monitor" nib; we
//  reach its non-NSView methods through AnyObject message dispatch (like QSO)
//  so we do not have to pull Oscilloscope.h into the bridging header.
@objc(_RTTYMonitorScopeView) private protocol ScopeViewMethods {
    @objc func setDisplayStyle(_ inStyle: Int32, plotColor: NSColor?)
    @objc func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>)
    @objc func addData(_ stream: UnsafeMutablePointer<CMDataStream>?, isBaudot: DarwinBoolean, timebase: Int32)
}

@objc(RTTYMonitor)
class RTTYMonitor: CMTappedPipe {

    //  matches the C "Connection" struct in RTTYMonitor.h
    private struct Connection {
        var pipe: CMTappedPipe?
        var index: Int32 = 0
        var enableBaudotMarkers: DarwinBoolean = false
        var timebase: Int32 = 0
    }

    //  outlets connected by Monitor.nib -- names must match nib keys exactly
    @objc var scopeView: NSView!
    @objc var styleArray: NSMatrix!
    @objc var sourceArray: NSMatrix!
    @objc var specLabel: NSMatrix!

    private var connection = [Connection](repeating: Connection(), count: 8)
    //  index of the currently selected connection, or -1 when none (see PSKMonitor)
    private var selectedIndex: Int = -1
    private var currentStyle: Int32 = 0
    private var timebase: Int32 = 0
    private var enableBaudotMarkers: DarwinBoolean = false

    private static let freqLabel = ["500", "1000", "1500", "2000", "2500"]

    //  RTTYMonitor is an AudioDest
    //
    //  Note: the C -init returned nil on nib-load failure; Swift cannot override
    //  NSObject's non-failable -init with a failable one, so this always returns
    //  an object and every scopeView access is guarded (see PSKMonitor.swift).
    @objc override init() {
        super.init()
        currentStyle = 0
        for i in 0..<8 {
            connection[i].pipe = nil
            connection[i].enableBaudotMarkers = false
            connection[i].index = Int32(truncatingIfNeeded: i)
        }
        selectedIndex = -1

        if Bundle.main.loadNibNamed("Monitor", owner: self, topLevelObjects: nil) {
            //  loadNib should have set up scopeView connection
            if let window = scopeView?.window {
                window.level = .normal
                window.hidesOnDeactivate = false
            }
        }
    }

    //  (Private API)
    private func changeStyle(to index: Int32) {
        styleArray?.deselectAllCells()
        styleArray?.selectCell(atRow: 0, column: Int(index))

        for i in 0..<5 {
            let text = specLabel?.cell(atRow: 0, column: i)
            text?.stringValue = (index == 0) ? RTTYMonitor.freqLabel[i] : ""
        }
        currentStyle = index
        (scopeView as AnyObject?)?.setDisplayStyle?(index, plotColor: nil)
    }

    //  (Private API)
    private func changeSource(to index: Int) {
        if connection[index].pipe == nil {
            sourceArray?.deselectSelectedCell()
            NotificationCenter.default.post(name: NSNotification.Name("SysBeep"), object: nil)
            return
        }
        //  remove old connection
        if selectedIndex >= 0 { connection[selectedIndex].pipe?.setTap(nil) }

        //  set new connection
        selectedIndex = index
        connection[index].pipe?.setTap(self)
        sourceArray?.deselectAllCells()
        sourceArray?.selectCell(atRow: 0, column: index)
        enableBaudotMarkers = connection[index].enableBaudotMarkers
        timebase = connection[index].timebase
    }

    @objc(connect:to:title:baudotMarkers:timebase:)
    func connect(_ index: Int32, to pipe: CMTappedPipe?, title name: String, baudotMarkers baudot: DarwinBoolean, timebase inTimebase: Int32) {
        //  remove old connection
        if selectedIndex >= 0 { connection[selectedIndex].pipe?.setTap(nil) }

        if let cell = sourceArray?.cell(atRow: 0, column: Int(index)) as? NSButtonCell {
            cell.title = name
        }
        connection[Int(index)].pipe = pipe
        connection[Int(index)].enableBaudotMarkers = baudot
        connection[Int(index)].timebase = inTimebase
        changeSource(to: Int(index))
    }

    //  data arrived from sound source
    override func importData(_ pipe: CMPipe!) {
        if let window = scopeView?.window, window.isVisible {
            let data = pipe.stream()
            (scopeView as AnyObject?)?.addData?(data, isBaudot: enableBaudotMarkers, timebase: timebase)
        }
        //  rtty monitor has no destination
    }

    @objc(setTitle:)
    func setTitle(_ title: String) {
        scopeView?.window?.title = title
    }

    @objc(setTonePairMarker:)
    func setTonePairMarker(_ tonepair: UnsafePointer<CMTonePair>) {
        (scopeView as AnyObject?)?.setTonePairMarker?(tonepair)
    }

    @objc func showWindow() {
        scopeView?.window?.orderFront(self)
    }

    @objc(setPlotColor:)
    func setPlotColor(_ color: NSColor?) {
        (scopeView as AnyObject?)?.setDisplayStyle?(currentStyle, plotColor: color)
    }

    @objc(hideScopeOnDeactivation:)
    func hideScopeOnDeactivation(_ hide: DarwinBoolean) {
        scopeView?.window?.hidesOnDeactivate = hide.boolValue
    }

    @objc(styleChanged:)
    func styleChanged(_ sender: Any?) {
        let tag = styleArray?.selectedCell()?.tag ?? 0
        changeStyle(to: Int32(truncatingIfNeeded: tag))
    }

    @objc(sourceChanged:)
    func sourceChanged(_ sender: Any?) {
        let index = Int((sender as? NSMatrix)?.selectedCell()?.tag ?? 0)

        //  default style
        switch index {
        case 0, 1:
            changeStyle(to: 0)              //  spectrum
            styleArray?.cell(atRow: 0, column: 0)?.isEnabled = true
        case 2, 3, 4:
            changeStyle(to: 1)              //  waveform
            styleArray?.cell(atRow: 0, column: 0)?.isEnabled = false
        default:
            break
        }
        changeSource(to: index)
    }
}
