// The production targets receive this initializer from xDrip/Extensions/UInt16.swift.
// Keep the command-line Libre tests independent of that file's unrelated UI helpers.
extension UInt16 {
    init(_ high: UInt8, _ low: UInt8) {
        self = UInt16(high) << 8 + UInt16(low)
    }
}
