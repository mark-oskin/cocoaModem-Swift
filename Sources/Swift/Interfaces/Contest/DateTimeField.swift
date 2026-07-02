//
//  DateTimeField.swift
//  cocoaModem 2.0
//
//  Created by Kok Chen on 12/26/05.
//  Swift port of DateTimeField.m.
//

import Cocoa

@objc(DateTimeField)
class DateTimeField: NSTextField {

    @objc(setContestFont:)
    func setContestFont(_ notify: Notification) {
        guard let font = notify.object as? NSFont else { return }
        let size = font.pointSize * 0.875
        let name = font.fontName
        self.font = NSFont(name: name, size: size)
    }

    override func awakeFromNib() {
        //  accepts fontChanges messages here
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(setContestFont(_:)),
                                               name: NSNotification.Name("ContestFont"),
                                               object: nil)
    }
}
