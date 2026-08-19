import Foundation

enum Libre2DirectConstants {
    static let serviceUUIDString = "FDE3"
    static let writeCharacteristicUUIDString = "F001"
    static let receiveCharacteristicUUIDString = "F002"
    static let encryptedFrameLength = 46
    static let decryptedFrameLength = 44
    static let maximumFragmentGap: TimeInterval = 3
}

enum Libre2DirectAlgorithmError: LocalizedError, Equatable {
    case invalidSensorUID
    case invalidPatchInfo
    case badEncryptedFrameLength(Int)
    case badDecryptedFrameLength(Int)
    case crcMismatch
    case invalidGlucose(rawGlucose: Int, rawTemperature: Int, derivedGlucose: Double, selectedGlucose: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSensorUID:
            return "Sensor UID must contain exactly 8 bytes"
        case .invalidPatchInfo:
            return "Patch info must contain at least 6 bytes"
        case let .badEncryptedFrameLength(length):
            return "Expected 46 encrypted bytes, received \(length)"
        case let .badDecryptedFrameLength(length):
            return "Expected 44 decrypted bytes, received \(length)"
        case .crcMismatch:
            return "BLE data decryption failed"
        case let .invalidGlucose(rawGlucose, rawTemperature, derivedGlucose, selectedGlucose):
            return String(
                format: "Decoded glucose is outside the valid diagnostic range (raw=%d, temperature=%d, derived=%.1f, selected=%.1f)",
                rawGlucose,
                rawTemperature,
                derivedGlucose,
                selectedGlucose
            )
        }
    }
}

enum Libre2DirectReadingSource: String, Equatable {
    case watchSensorF002
    case iphoneWatchConnectivity
}

struct Libre2DirectReading: Equatable {
    let glucoseMGDL: Double
    let trendMGDLPerMinute: Double?
    let sensorTimeInMinutes: UInt16
    let receivedAt: Date
    let source: Libre2DirectReadingSource

    var canDisplayDirectFromSensor: Bool {
        source == .watchSensorF002
    }

    var trendSymbol: String? {
        guard let trendMGDLPerMinute else { return nil }
        if trendMGDLPerMinute >= 3 { return "↑" }
        if trendMGDLPerMinute >= 1 { return "↗" }
        if trendMGDLPerMinute < -3 { return "↓" }
        if trendMGDLPerMinute < -1 { return "↘" }
        return "→"
    }
}

struct Libre2DirectFrameAssembler: Equatable {
    private(set) var buffer = Data()
    private(set) var fragmentCount = 0
    private(set) var completeFrameCount = 0
    private(set) var lastCompleteFrameAt: Date?
    private var lastFragmentAt: Date?

    var assembledByteCount: Int { buffer.count }

    mutating func append(fragment: Data, at date: Date) throws -> Data? {
        if let lastFragmentAt,
           date.timeIntervalSince(lastFragmentAt) > Libre2DirectConstants.maximumFragmentGap {
            buffer.removeAll(keepingCapacity: true)
        }

        lastFragmentAt = date
        fragmentCount += 1
        buffer.append(fragment)

        guard buffer.count <= Libre2DirectConstants.encryptedFrameLength else {
            let invalidLength = buffer.count
            resetFrame()
            throw Libre2DirectAlgorithmError.badEncryptedFrameLength(invalidLength)
        }

        guard buffer.count == Libre2DirectConstants.encryptedFrameLength else {
            return nil
        }

        let frame = buffer
        completeFrameCount += 1
        lastCompleteFrameAt = date
        resetFrame()
        return frame
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        fragmentCount = 0
        completeFrameCount = 0
        lastCompleteFrameAt = nil
        lastFragmentAt = nil
    }

    private mutating func resetFrame() {
        buffer.removeAll(keepingCapacity: true)
        lastFragmentAt = nil
    }
}

enum Libre2DirectAlgorithms {
    static func streamingUnlockPayload(
        sensorUID: Data,
        patchInfo: Data,
        enableTime: UInt32,
        unlockCount: UInt16
    ) -> [UInt8] {
        precondition(sensorUID.count == 8, "Libre sensor UID must contain 8 bytes")
        precondition(patchInfo.count >= 6, "Libre patch info must contain at least 6 bytes")

        // This is the existing xDrip Libre2BLEUtilities.streamingUnlockPayload algorithm,
        // extracted unchanged so iOS and watchOS use one implementation.
        let time = enableTime + UInt32(unlockCount)
        let b: [UInt8] = [
            UInt8(time & 0xFF),
            UInt8((time >> 8) & 0xFF),
            UInt8((time >> 16) & 0xFF),
            UInt8((time >> 24) & 0xFF)
        ]

        let ad = PreLibre2.usefulFunction(sensorUID: sensorUID, x: 0x1b, y: 0x1b6a)
        let ed = PreLibre2.usefulFunction(
            sensorUID: sensorUID,
            x: 0x1e,
            y: UInt16(enableTime & 0xFFFF) ^ UInt16(patchInfo[5], patchInfo[4])
        )

        let t11 = UInt16(ed[1], ed[0]) ^ UInt16(b[3], b[2])
        let t12 = UInt16(ad[1], ad[0])
        let t13 = UInt16(ed[3], ed[2]) ^ UInt16(b[1], b[0])
        let t14 = UInt16(ad[3], ad[2])
        let t2 = PreLibre2.processCrypto(
            input: PreLibre2.prepareVariables2(
                sensorUID: sensorUID,
                i1: t11,
                i2: t12,
                i3: t13,
                i4: t14
            )
        )

        let t31 = crc16(Data([
            0xc1, 0xc4, 0xc3, 0xc0, 0xd4, 0xe1, 0xe7, 0xba,
            UInt8(t2[0] & 0xFF), UInt8((t2[0] >> 8) & 0xFF)
        ])).byteSwapped
        let t32 = crc16(Data([
            UInt8(t2[1] & 0xFF), UInt8((t2[1] >> 8) & 0xFF),
            UInt8(t2[2] & 0xFF), UInt8((t2[2] >> 8) & 0xFF),
            UInt8(t2[3] & 0xFF), UInt8((t2[3] >> 8) & 0xFF)
        ])).byteSwapped
        let t33 = crc16(Data([ad[0], ad[1], ad[2], ad[3], ed[0], ed[1]])).byteSwapped
        let t34 = crc16(Data([ed[2], ed[3], b[0], b[1], b[2], b[3]])).byteSwapped
        let t4 = PreLibre2.processCrypto(
            input: PreLibre2.prepareVariables2(
                sensorUID: sensorUID,
                i1: t31,
                i2: t32,
                i3: t33,
                i4: t34
            )
        )

        return [
            b[0], b[1], b[2], b[3],
            UInt8(t4[0] & 0xFF), UInt8((t4[0] >> 8) & 0xFF),
            UInt8(t4[1] & 0xFF), UInt8((t4[1] >> 8) & 0xFF),
            UInt8(t4[2] & 0xFF), UInt8((t4[2] >> 8) & 0xFF),
            UInt8(t4[3] & 0xFF), UInt8((t4[3] >> 8) & 0xFF)
        ]
    }

    static func decryptBLE(sensorUID: Data, data: Data) throws -> Data {
        guard sensorUID.count == 8 else { throw Libre2DirectAlgorithmError.invalidSensorUID }
        guard data.count == Libre2DirectConstants.encryptedFrameLength else {
            throw Libre2DirectAlgorithmError.badEncryptedFrameLength(data.count)
        }

        // This is the existing xDrip Libre2BLEUtilities.decryptBLE algorithm,
        // including its CRC check.
        let d = PreLibre2.usefulFunction(sensorUID: sensorUID, x: 0x1b, y: 0x1b6a)
        let x = UInt16(d[1], d[0]) ^ UInt16(d[3], d[2]) | 0x63
        let y = UInt16(data[1], data[0]) ^ 0x63

        var key = [UInt8]()
        var initialKey = PreLibre2.processCrypto(
            input: PreLibre2.prepareVariables(sensorUID: sensorUID, x: x, y: y)
        )

        for _ in 0 ..< 8 {
            key.append(UInt8(truncatingIfNeeded: initialKey[0]))
            key.append(UInt8(truncatingIfNeeded: initialKey[0] >> 8))
            key.append(UInt8(truncatingIfNeeded: initialKey[1]))
            key.append(UInt8(truncatingIfNeeded: initialKey[1] >> 8))
            key.append(UInt8(truncatingIfNeeded: initialKey[2]))
            key.append(UInt8(truncatingIfNeeded: initialKey[2] >> 8))
            key.append(UInt8(truncatingIfNeeded: initialKey[3]))
            key.append(UInt8(truncatingIfNeeded: initialKey[3] >> 8))
            initialKey = PreLibre2.processCrypto(input: initialKey)
        }

        let result = data.dropFirst(2).enumerated().map { index, value in
            value ^ key[index]
        }

        guard crc16(Data(result.prefix(42))) == UInt16(result[42], result[43]) else {
            throw Libre2DirectAlgorithmError.crcMismatch
        }
        return Data(result)
    }

    static func parseDirectReading(
        decryptedData: Data,
        parameters: LibreWatchAlgorithmParameters,
        receivedAt: Date
    ) throws -> Libre2DirectReading {
        guard decryptedData.count == Libre2DirectConstants.decryptedFrameLength else {
            throw Libre2DirectAlgorithmError.badDecryptedFrameLength(decryptedData.count)
        }

        let newest = glucoseSample(from: decryptedData, sampleIndex: 0, parameters: parameters)
        // The second transmitted sample represents the reading from two minutes ago.
        let previous = glucoseSample(from: decryptedData, sampleIndex: 1, parameters: parameters)
        let maximumSelectedGlucose = newest.derivedGlucose > 0
            ? 3_000
            : 3_000 * ConstantsBloodGlucose.libreMultiplier
        guard newest.selectedGlucose.isFinite,
              newest.selectedGlucose > 0,
              newest.selectedGlucose <= maximumSelectedGlucose
        else {
            throw Libre2DirectAlgorithmError.invalidGlucose(
                rawGlucose: newest.rawGlucose,
                rawTemperature: newest.rawTemperature,
                derivedGlucose: newest.derivedGlucose,
                selectedGlucose: newest.selectedGlucose
            )
        }

        let sensorTime = UInt16(decryptedData[41], decryptedData[40])
        let trend = previous.selectedGlucose.isFinite && previous.selectedGlucose > 0
            ? (newest.selectedGlucose - previous.selectedGlucose) / 2
            : nil

        return Libre2DirectReading(
            glucoseMGDL: newest.selectedGlucose,
            trendMGDLPerMinute: trend,
            sensorTimeInMinutes: sensorTime,
            receivedAt: receivedAt,
            source: .watchSensorF002
        )
    }

    private static func glucoseSample(
        from data: Data,
        sampleIndex: Int,
        parameters: LibreWatchAlgorithmParameters
    ) -> (rawGlucose: Int, rawTemperature: Int, derivedGlucose: Double, selectedGlucose: Double) {
        let byteOffset = sampleIndex * 4
        let rawGlucose = readBits(data, byteOffset: byteOffset, bitOffset: 0, bitCount: 0xe)
        let rawTemperature = readBits(data, byteOffset: byteOffset, bitOffset: 0xe, bitCount: 0xc) << 2
        var temperatureAdjustment = readBits(
            data,
            byteOffset: byteOffset,
            bitOffset: 0x1a,
            bitCount: 0x5
        ) << 2
        if readBits(data, byteOffset: byteOffset, bitOffset: 0x1f, bitCount: 1) != 0 {
            temperatureAdjustment = -temperatureAdjustment
        }

        // Keep the same inputs and formula used by LibreMeasurement's proven
        // temperature algorithm. The adjustment is decoded above exactly as in
        // Libre2BLEUtilities; the derived parameters already incorporate the
        // sensor-specific NFC calibration data.
        _ = temperatureAdjustment
        let slope = parameters.slopeSlope * Double(rawTemperature) + parameters.offsetSlope
        let offset = parameters.slopeOffset * Double(rawTemperature) + parameters.offsetOffset
        let glucose = slope * Double(rawGlucose) + offset
        let derivedGlucose = glucose * parameters.extraSlope + parameters.extraOffset

        // Match Libre2BLEUtilities.parseBLEData exactly: the iPhone parser uses
        // the NFC-derived value only when it is positive, otherwise it falls
        // back to the existing Libre raw scaling instead of rejecting the frame.
        let selectedGlucose = derivedGlucose > 0
            ? derivedGlucose
            : Double(rawGlucose) * ConstantsBloodGlucose.libreMultiplier

        return (rawGlucose, rawTemperature, derivedGlucose, selectedGlucose)
    }

    private static func readBits(
        _ buffer: Data,
        byteOffset: Int,
        bitOffset: Int,
        bitCount: Int
    ) -> Int {
        guard bitCount > 0 else { return 0 }
        var result = 0
        for index in 0 ..< bitCount {
            let totalBitOffset = byteOffset * 8 + bitOffset + index
            let byteIndex = totalBitOffset / 8
            let bitIndex = totalBitOffset % 8
            if ((buffer[byteIndex] >> bitIndex) & 1) == 1 {
                result |= 1 << index
            }
        }
        return result
    }

    private static func crc16(_ data: Data) -> UInt16 {
        let table: [UInt16] = [0, 4489, 8978, 12955, 17956, 22445, 25910, 29887, 35912, 40385, 44890, 48851, 51820, 56293, 59774, 63735, 4225, 264, 13203, 8730, 22181, 18220, 30135, 25662, 40137, 36160, 49115, 44626, 56045, 52068, 63999, 59510, 8450, 12427, 528, 5017, 26406, 30383, 17460, 21949, 44362, 48323, 36440, 40913, 60270, 64231, 51324, 55797, 12675, 8202, 4753, 792, 30631, 26158, 21685, 17724, 48587, 44098, 40665, 36688, 64495, 60006, 55549, 51572, 16900, 21389, 24854, 28831, 1056, 5545, 10034, 14011, 52812, 57285, 60766, 64727, 34920, 39393, 43898, 47859, 21125, 17164, 29079, 24606, 5281, 1320, 14259, 9786, 57037, 53060, 64991, 60502, 39145, 35168, 48123, 43634, 25350, 29327, 16404, 20893, 9506, 13483, 1584, 6073, 61262, 65223, 52316, 56789, 43370, 47331, 35448, 39921, 29575, 25102, 20629, 16668, 13731, 9258, 5809, 1848, 65487, 60998, 56541, 52564, 47595, 43106, 39673, 35696, 33800, 38273, 42778, 46739, 49708, 54181, 57662, 61623, 2112, 6601, 11090, 15067, 20068, 24557, 28022, 31999, 38025, 34048, 47003, 42514, 53933, 49956, 61887, 57398, 6337, 2376, 15315, 10842, 24293, 20332, 32247, 27774, 42250, 46211, 34328, 38801, 58158, 62119, 49212, 53685, 10562, 14539, 2640, 7129, 28518, 32495, 19572, 24061, 46475, 41986, 38553, 34576, 62383, 57894, 53437, 49460, 14787, 10314, 6865, 2904, 32743, 28270, 23797, 19836, 50700, 55173, 58654, 62615, 32808, 37281, 41786, 45747, 19012, 23501, 26966, 30943, 3168, 7657, 12146, 16123, 54925, 50948, 62879, 58390, 37033, 33056, 46011, 41522, 23237, 19276, 31191, 26718, 7393, 3432, 16371, 11898, 59150, 63111, 50204, 54677, 41258, 45219, 33336, 37809, 27462, 31439, 18516, 23005, 11618, 15595, 3696, 8185, 63375, 58886, 54429, 50452, 45483, 40994, 37561, 33584, 31687, 27214, 22741, 18780, 15843, 11370, 7921, 3960]
        var crc = data.reduce(UInt16(0xFFFF)) {
            ($0 >> 8) ^ table[Int(($0 ^ UInt16($1)) & 0xFF)]
        }
        var reversed = UInt16(0)
        for _ in 0 ..< 16 {
            reversed = reversed << 1 | crc & 1
            crc >>= 1
        }
        return reversed.byteSwapped
    }
}
