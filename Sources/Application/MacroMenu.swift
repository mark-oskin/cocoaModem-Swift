//
//  MacroMenu.swift
//  cocoaModem 2.0
//
//  Swift port of MacroMenu.m (Kok Chen, 7/4/04).
//

import Cocoa

@objc(MacroMenu)
class MacroMenu: NSObject, NSOutlineViewDataSource {
    private var rootNode = [MacroNode?](repeating: nil, count: 6)

    private func addGeneral(_ node: MacroNode) {
        node.addChild(MacroNode(name: "\\n", function: "new line"))
        node.addChild(MacroNode(name: "\\r", function: "carriage return"))
        node.addChild(MacroNode(name: "", function: "-----"))
        node.addChild(MacroNode(name: "%b", function: "brag tape"))
        node.addChild(MacroNode(name: "%c", function: "my callsign"))
        node.addChild(MacroNode(name: "%C", function: "DX callsign"))
        node.addChild(MacroNode(name: "%h", function: "my name"))
        node.addChild(MacroNode(name: "%H", function: "DX name"))
    }

    private func addContest(_ node: MacroNode) {
        node.addChild(MacroNode(name: "%a", function: "ARRL section"))
        node.addChild(MacroNode(name: "%g", function: "grid square"))
        node.addChild(MacroNode(name: "%n", function: "QSO Number"))
        node.addChild(MacroNode(name: "%o", function: "Cut Number (0 substituted by T)"))
        node.addChild(MacroNode(name: "%N", function: "Cut Number (1/A,9/N,0/T)"))
        node.addChild(MacroNode(name: "%p", function: "previous QSO Number"))
        node.addChild(MacroNode(name: "%P", function: "previous registered UTC time"))
        node.addChild(MacroNode(name: "%s", function: "state/province/DX"))
        node.addChild(MacroNode(name: "%t", function: "UTC time hhmm"))
        node.addChild(MacroNode(name: "%T", function: "registered UTC time"))
        node.addChild(MacroNode(name: "%x", function: "contest exchange"))
        node.addChild(MacroNode(name: "%X", function: "received contest exchange"))
        node.addChild(MacroNode(name: "%y", function: "year licensed"))
        node.addChild(MacroNode(name: "%z", function: "CQ zone"))
        node.addChild(MacroNode(name: "%Z", function: "ITU zone"))
    }

    private func addRTTY(_ node: MacroNode) {
        node.addChild(MacroNode(name: "%[tx]", function: "switch to transmit"))
        node.addChild(MacroNode(name: "%[rx]", function: "return to receive"))
        node.addChild(MacroNode(name: "%[b1]", function: "narrow bandwidth"))
        node.addChild(MacroNode(name: "%[b2]", function: "normal bandwidth"))
        node.addChild(MacroNode(name: "%[b3]", function: "wide bandwidth"))
        node.addChild(MacroNode(name: "%[d1]", function: "M/S demod"))
        node.addChild(MacroNode(name: "%[d2]", function: "MP- demod"))
        node.addChild(MacroNode(name: "%[d3]", function: "MP+ demod"))
    }

    private func addPSK(_ node: MacroNode) {
        node.addChild(MacroNode(name: "%[tx]", function: "switch to transmit"))
        node.addChild(MacroNode(name: "%[rx]", function: "return to receive"))
    }

    override init() {
        super.init()
        rootNode[0] = MacroNode()
        rootNode[0]!.setNodeName("General", function: "")
        addGeneral(rootNode[0]!)
        rootNode[1] = MacroNode()
        rootNode[1]!.setNodeName("Contest", function: "")
        addContest(rootNode[1]!)
        rootNode[2] = MacroNode()
        rootNode[2]!.setNodeName("RTTY", function: "")
        addRTTY(rootNode[2]!)
        rootNode[3] = MacroNode()
        rootNode[3]!.setNodeName("PSK", function: "")
        addPSK(rootNode[3]!)
    }

    //  NSOutlineView data source (connected in MainMenu.nib)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? MacroNode else {
            //  number of base objects
            return 4
        }
        return Int(node.childrenCount())
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? MacroNode else { return false }
        return node.childrenCount() > 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? MacroNode {
            return node.child(at: Int32(index)) as Any
        }
        return rootNode[index]!
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        let node = item as? MacroNode

        if tableColumn?.identifier.rawValue == "Function" {
            return node?.nodeFunction()
        }
        return node?.nodeName()
    }
}
