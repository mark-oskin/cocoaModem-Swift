//
//  PSKMonitor.swift
//  cocoaModem
//
//  Created by Kok Chen on Tue Jul 27 2004.
//
//  Swift port of PSKMonitor.m.  PSKMonitor remains a subclass of the
//  Objective-C DSP pipe base CMTappedPipe (CMTappedPipe stays Objective-C;
//  its header is in the bridging header).
//

import Cocoa

//  Informal, dynamically dispatched access to the Oscilloscope scope view.
//  Oscilloscope is an NSView subclass connected through the "Monitor" nib; we
//  reach its non-NSView methods through AnyObject message dispatch (like QSO)
//  so we do not have to pull Oscilloscope.h into the bridging header.
@objc(_PSKMonitorScopeView) private protocol ScopeViewMethods {
    @objc func setDisplayStyle(_ inStyle: Int32, plotColor: NSColor?)
    @objc func addData(_ stream: UnsafeMutablePointer<CMDataStream>?, isBaudot: DarwinBoolean, timebase: Int32)
}

@objc(PSKMonitor)
class PSKMonitor: CMTappedPipe {

    //  matches the C "Connection" struct in PSKMonitor.h
    private struct Connection {
        var pipe: CMTappedPipe?
        var index: Int32 = 0
    }

    //  outlets connected by Monitor.nib -- names must match nib keys exactly
    @objc var scopeView: NSView!
    @objc var styleArray: NSMatrix!
    @objc var sourceArray: NSMatrix!
    @objc var specLabel: NSMatrix!

    private var connection = [Connection](repeating: Connection(), count: 8)
    //  index of the currently selected connection, or -1 when none (the C code
    //  used a "Connection *selected" pointer into the array; an index is the
    //  safe Swift equivalent and avoids dangling pointers into a Swift array).
    private var selectedIndex: Int = -1
    private var currentStyle: Int32 = 0

    private static let freqLabel = ["500", "1000", "1500", "2000", "2500"]

    //  PSKMonitor is an AudioDest
    //
    //  Note: the C -init returned nil if the nib failed to load or scopeView was
    //  unset.  Swift cannot override NSObject's non-failable -init with a
    //  failable one, so this always returns an object; every scopeView access is
    //  guarded (optional-chained), matching the original messages-to-nil safety.
    @objc override init() {
        super.init()
        currentStyle = 0
        for i in 0..<8 {
            connection[i].pipe = nil
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

    /* local */
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
    }

    @objc(connect:to:title:)
    func connect(_ index: Int32, to pipe: CMTappedPipe?, title name: String) {
        //  remove old connection
        if selectedIndex >= 0 { connection[selectedIndex].pipe?.setTap(nil) }

        if let cell = sourceArray?.cell(atRow: 0, column: Int(index)) as? NSButtonCell {
            cell.title = name
        }
        connection[Int(index)].pipe = pipe
        changeSource(to: Int(index))
    }

    //  data arrived from sound source
    override func importData(_ pipe: CMPipe!) {
        if let window = scopeView?.window, window.isVisible {
            let data = pipe.stream()
            (scopeView as AnyObject?)?.addData?(data, isBaudot: false, timebase: 1)
        }
        //  PSK monitor has no destination
    }

    @objc(setTitle:)
    func setTitle(_ title: String) {
        scopeView?.window?.title = title
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
        let button = (sender as? NSMatrix)?.selectedCell()
        let index = Int32(truncatingIfNeeded: button?.tag ?? 0)
        styleArray?.deselectAllCells()
        styleArray?.selectCell(atRow: 0, column: Int(index))

        for i in 0..<5 {
            let text = specLabel?.cell(atRow: 0, column: i)
            text?.stringValue = (index == 0) ? PSKMonitor.freqLabel[i] : ""
        }
        switch index {
        case 0, 1:
            currentStyle = index
            (scopeView as AnyObject?)?.setDisplayStyle?(index, plotColor: nil)
        default:
            break
        }
    }

    @objc(sourceChanged:)
    func sourceChanged(_ sender: Any?) {
        let button = (sender as? NSMatrix)?.selectedCell()
        let index = Int(button?.tag ?? 0)
        changeSource(to: index)
    }
}
