//
//  FAXView.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 3/27/06.
//  Swift port of FAXView.m.
//
//  The shared C types (BackingFrame + the MAXFAXHEIGHT / MAXBACKING / BACKGROUND
//  macros) live in FAXFrame.h and are consumed here through the bridging header.
//  FAXView is the NSImageView base class; FAXDisplay subclasses it.
//
//  Note on the ppm accessor: the Obj-C original had BOTH a `float ppm` ivar and a
//  `-(float)ppm` getter method.  Swift cannot host a stored property and a method
//  that share the name `ppm`, so the ivar is renamed `ppmValue` while the getter
//  keeps its `ppm` selector.  Subclasses read/write `ppmValue` directly.
//

import Cocoa

@objc(FAXView)
class FAXView: NSImageView {

    //  base ivars accessed by the FAXDisplay subclass -> internal
    internal var faxFrame: FAXFrame!
    internal var ppmValue: Float = 0          //  was the Obj-C `float ppm` ivar (A/D clock adjustment)

    //  private ivars
    private var dumpLock: NSLock!
    private var dumpName: String?
    private var dumpBackingFrame: UnsafeMutablePointer<BackingFrame>?

    override init(frame imageframe: NSRect) {
        super.init(frame: imageframe)
        let bsize = self.bounds.size
        faxFrame = FAXFrame(width: Int32(bsize.width), height: Int32(bsize.height))
        self.imageScaling = .scaleNone
        self.image = faxFrame?.image()
        dumpLock = NSLock()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isOpaque: Bool {
        return true
    }

    override func awakeFromNib() {
        faxFrame?.setSamplingParameters()
    }

    //  (Test purpose)
    @objc func physicalMemory() -> Int32 {
        var tinfo = task_basic_info()
        var tsize = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &tinfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tsize)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &tsize)
            }
        }
        if result != KERN_SUCCESS { return 0 }
        return Int32(tinfo.resident_size / 1024 / 1024)
    }

    //  (Test purpose)
    @objc(vmUse:)
    func vmUse(_ title: UnsafeMutablePointer<CChar>) {
        var tinfo = task_basic_info()
        var tsize = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &tinfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tsize)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &tsize)
            }
        }
        if result == KERN_SUCCESS {
            print(String(format: "%48s -- VM: %5d Physical %5d", title,
                         Int32(tinfo.virtual_size / 1024 / 1024),
                         Int32(tinfo.resident_size / 1024 / 1024)))
        }
    }

    //  set from Plist
    @objc(setPPM:)
    func setPPM(_ value: Float) {
        ppmValue = value
        faxFrame?.setPPM(ppmValue)
        faxFrame?.setSamplingParameters()
    }

    //  retrieve for Plist
    @objc func ppm() -> Float {
        return ppmValue
    }

    //  v0.80 swap to a new NSBitmapImageRep, since Snow Leopard appears to cache it.
    //  This is called whenever the image changes and needs to be displayed on the screen.
    @objc func swapImageRep() {
        faxFrame?.swapImageRep()
    }
}
