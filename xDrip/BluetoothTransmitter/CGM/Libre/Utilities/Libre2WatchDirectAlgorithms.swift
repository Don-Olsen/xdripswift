import Foundation

enum Libre2WatchDirectConstants {
    static let serviceUUIDString = "FDE3"
    static let writeCharacteristicUUIDString = "F001"
    static let receiveCharacteristicUUIDString = "F002"
    static let encryptedFrameLength = 46
    static let decryptedFrameLength = 44
    static let maximumFragmentGap: TimeInterval = 3
}

enum Libre2WatchDirectAlgorithmError: LocalizedError, Equatable {
    case invalidSensorUID
    case invalidPatchInfo
    case badEncryptedFrameLength(Int)
    case badDecryptedFrameLength(Int)
    case crcMismatch
    case invalidGlucose

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
            return "Libre BLE CRC validation failed"
        case .invalidGlucose:
            return "Decoded glucose is outside the valid range"
        }
    }
}

struct Libre2WatchDirectReading: Equatable {
    let nativeGlucoseMGDL: Double
    let previousNativeGlucoseMGDL: Double
    let rawGlucose: UInt16
    let previousRawGlucose: UInt16
    let sensorTimeInMinutes: UInt16
    let receivedAt: Date

    var nativeTrendMGDLPerMinute: Double {
        (nativeGlucoseMGDL - previousNativeGlucoseMGDL) / 2
    }

    func payload(
        sessionID: UUID,
        valueDomain: LibreWatchValueDomain,
        calibrationRevision: UInt64
    ) -> LibreWatchDirectReadingPayload {
        LibreWatchDirectReadingPayload(
            sessionID: sessionID,
            valueDomain: valueDomain,
            nativeGlucoseMGDL: nativeGlucoseMGDL,
            previousNativeGlucoseMGDL: previousNativeGlucoseMGDL,
            rawGlucose: rawGlucose,
            previousRawGlucose: previousRawGlucose,
            sensorTimeInMinutes: sensorTimeInMinutes,
            receivedAt: receivedAt,
            calibrationRevision: calibrationRevision
        )
    }
}

struct Libre2WatchDirectFrameAssembler: Equatable {
    private(set) var buffer = Data()
    private(set) var fragmentCount = 0
    private(set) var completeFrameCount = 0
    private(set) var lastCompleteFrameAt: Date?
    private var lastFragmentAt: Date?

    var assembledByteCount: Int { buffer.count }

    mutating func append(fragment: Data, at date: Date) throws -> Data? {
        if let lastFragmentAt,
           date.timeIntervalSince(lastFragmentAt) > Libre2WatchDirectConstants.maximumFragmentGap {
            buffer.removeAll(keepingCapacity: true)
        }

        lastFragmentAt = date
        fragmentCount += 1
        buffer.append(fragment)

        guard buffer.count <= Libre2WatchDirectConstants.encryptedFrameLength else {
            let invalidLength = buffer.count
            resetCurrentFrame()
            throw Libre2WatchDirectAlgorithmError.badEncryptedFrameLength(invalidLength)
        }

        guard buffer.count == Libre2WatchDirectConstants.encryptedFrameLength else { return nil }

        let frame = buffer
        completeFrameCount += 1
        lastCompleteFrameAt = date
        resetCurrentFrame()
        return frame
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        fragmentCount = 0
        completeFrameCount = 0
        lastCompleteFrameAt = nil
        lastFragmentAt = nil
    }

    private mutating func resetCurrentFrame() {
        buffer.removeAll(keepingCapacity: true)
        lastFragmentAt = nil
    }
}

/// watchOS-safe copy of the established Libre 2 crypto and calibration path.
/// The input values are the same NFC-derived values used by the iPhone collector.
enum Libre2WatchDirectAlgorithms {
    static func streamingUnlockPayload(
        sensorUID: Data,
        patchInfo: Data,
        enableTime: UInt32,
        unlockCount: UInt16
    ) throws -> [UInt8] {
        guard sensorUID.count == 8 else { throw Libre2WatchDirectAlgorithmError.invalidSensorUID }
        guard patchInfo.count >= 6 else { throw Libre2WatchDirectAlgorithmError.invalidPatchInfo }

        let time = enableTime + UInt32(unlockCount)
        let timeBytes: [UInt8] = [
            UInt8(time & 0xFF),
            UInt8((time >> 8) & 0xFF),
            UInt8((time >> 16) & 0xFF),
            UInt8((time >> 24) & 0xFF)
        ]

        let activationData = PreLibre2.usefulFunction(sensorUID: sensorUID, x: 0x1b, y: 0x1b6a)
        let enableData = PreLibre2.usefulFunction(
            sensorUID: sensorUID,
            x: 0x1e,
            y: UInt16(enableTime & 0xFFFF) ^ word(patchInfo[5], patchInfo[4])
        )

        let firstBlock = PreLibre2.processCrypto(input: PreLibre2.prepareVariables2(
            sensorUID: sensorUID,
            i1: word(enableData[1], enableData[0]) ^ word(timeBytes[3], timeBytes[2]),
            i2: word(activationData[1], activationData[0]),
            i3: word(enableData[3], enableData[2]) ^ word(timeBytes[1], timeBytes[0]),
            i4: word(activationData[3], activationData[2])
        ))

        let secondBlock = PreLibre2.processCrypto(input: PreLibre2.prepareVariables2(
            sensorUID: sensorUID,
            i1: crc16(Data([
                0xc1, 0xc4, 0xc3, 0xc0, 0xd4, 0xe1, 0xe7, 0xba,
                UInt8(firstBlock[0] & 0xFF), UInt8((firstBlock[0] >> 8) & 0xFF)
            ])).byteSwapped,
            i2: crc16(Data([
                UInt8(firstBlock[1] & 0xFF), UInt8((firstBlock[1] >> 8) & 0xFF),
                UInt8(firstBlock[2] & 0xFF), UInt8((firstBlock[2] >> 8) & 0xFF),
                UInt8(firstBlock[3] & 0xFF), UInt8((firstBlock[3] >> 8) & 0xFF)
            ])).byteSwapped,
            i3: crc16(Data([
                activationData[0], activationData[1], activationData[2], activationData[3],
                enableData[0], enableData[1]
            ])).byteSwapped,
            i4: crc16(Data([
                enableData[2], enableData[3],
                timeBytes[0], timeBytes[1], timeBytes[2], timeBytes[3]
            ])).byteSwapped
        ))

        return timeBytes + secondBlock.flatMap {
            [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)]
        }
    }

    static func decryptBLE(sensorUID: Data, data: Data) throws -> Data {
        guard sensorUID.count == 8 else { throw Libre2WatchDirectAlgorithmError.invalidSensorUID }
        guard data.count == Libre2WatchDirectConstants.encryptedFrameLength else {
            throw Libre2WatchDirectAlgorithmError.badEncryptedFrameLength(data.count)
        }

        let derived = PreLibre2.usefulFunction(sensorUID: sensorUID, x: 0x1b, y: 0x1b6a)
        let x = word(derived[1], derived[0]) ^ word(derived[3], derived[2]) | 0x63
        let y = word(data[1], data[0]) ^ 0x63

        var key = [UInt8]()
        var block = PreLibre2.processCrypto(
            input: PreLibre2.prepareVariables(sensorUID: sensorUID, x: x, y: y)
        )

        for _ in 0 ..< 8 {
            for value in block {
                key.append(UInt8(truncatingIfNeeded: value))
                key.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            block = PreLibre2.processCrypto(input: block)
        }

        let decrypted = data.dropFirst(2).enumerated().map { index, value in
            value ^ key[index]
        }

        guard crc16(Data(decrypted.prefix(42))) == word(decrypted[42], decrypted[43]) else {
            throw Libre2WatchDirectAlgorithmError.crcMismatch
        }
        return Data(decrypted)
    }

    static func parseDirectReading(
        decryptedData: Data,
        parameters: LibreWatchAlgorithmParameters,
        receivedAt: Date
    ) throws -> Libre2WatchDirectReading {
        guard decryptedData.count == Libre2WatchDirectConstants.decryptedFrameLength else {
            throw Libre2WatchDirectAlgorithmError.badDecryptedFrameLength(decryptedData.count)
        }

        let newest = sample(from: decryptedData, sampleIndex: 0, parameters: parameters)
        let previous = sample(from: decryptedData, sampleIndex: 1, parameters: parameters)
        guard newest.nativeGlucoseMGDL.isFinite,
              newest.nativeGlucoseMGDL > 0,
              newest.nativeGlucoseMGDL <= 3_000,
              previous.nativeGlucoseMGDL.isFinite,
              previous.nativeGlucoseMGDL > 0,
              previous.nativeGlucoseMGDL <= 3_000,
              newest.rawGlucose > 0,
              previous.rawGlucose > 0
        else {
            throw Libre2WatchDirectAlgorithmError.invalidGlucose
        }

        return Libre2WatchDirectReading(
            nativeGlucoseMGDL: newest.nativeGlucoseMGDL,
            previousNativeGlucoseMGDL: previous.nativeGlucoseMGDL,
            rawGlucose: newest.rawGlucose,
            previousRawGlucose: previous.rawGlucose,
            sensorTimeInMinutes: word(decryptedData[41], decryptedData[40]),
            receivedAt: receivedAt
        )
    }

    private static func sample(
        from data: Data,
        sampleIndex: Int,
        parameters: LibreWatchAlgorithmParameters
    ) -> (rawGlucose: UInt16, nativeGlucoseMGDL: Double) {
        let byteOffset = sampleIndex * 4
        let rawGlucose = readBits(data, byteOffset: byteOffset, bitOffset: 0, bitCount: 0xe)
        let rawTemperature = readBits(data, byteOffset: byteOffset, bitOffset: 0xe, bitCount: 0xc) << 2
        let slope = parameters.slopeSlope * Double(rawTemperature) + parameters.offsetSlope
        let offset = parameters.slopeOffset * Double(rawTemperature) + parameters.offsetOffset
        let nativeGlucoseMGDL = (slope * Double(rawGlucose) + offset) * parameters.extraSlope + parameters.extraOffset
        return (UInt16(rawGlucose), nativeGlucoseMGDL)
    }

    private static func readBits(
        _ buffer: Data,
        byteOffset: Int,
        bitOffset: Int,
        bitCount: Int
    ) -> Int {
        var result = 0
        for index in 0 ..< bitCount {
            let absoluteBit = byteOffset * 8 + bitOffset + index
            if ((buffer[absoluteBit / 8] >> (absoluteBit % 8)) & 1) == 1 {
                result |= 1 << index
            }
        }
        return result
    }

    private static func word(_ high: UInt8, _ low: UInt8) -> UInt16 {
        UInt16(high) << 8 | UInt16(low)
    }

    /// Same reflected CRC-16 implementation used by Libre2BLEUtilities, expressed
    /// without its lookup table so the shared Watch source stays small.
    private static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0 ..< 8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }

        var reversed = UInt16(0)
        for _ in 0 ..< 16 {
            reversed = reversed << 1 | crc & 1
            crc >>= 1
        }
        return reversed.byteSwapped
    }
}
