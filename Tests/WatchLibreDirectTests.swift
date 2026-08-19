import Foundation

private enum DirectTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DirectTestFailure.failed(message) }
}

@main
struct WatchLibreDirectTests {
    static func main() throws {
        try testSessionSerializationAndValidation()
        try testIdentityMatching()
        try testOwnershipTransitions()
        try testLibreUUIDDefinitions()
        try testFrameAssembly()
        try testUnlockCounterInput()
        try testIPhoneParserFallback()
        try testDirectSourceGuarantee()
        try testStateTimeoutAndFailures()
        print("Watch Libre direct-test model tests passed")
    }

    private static func makeSession(
        sensorType: String = "C6",
        expectedName: String = "ABBOTTTEST123456"
    ) -> LibreWatchTestSession {
        LibreWatchTestSession(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            sensorUID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            patchInfo: Data([0xE5, 0, 0, 0, 0x34, 0x12]),
            sensorSerialNumber: "TEST123456",
            sensorTypeRawValue: sensorType,
            expectedPeripheralName: expectedName,
            unlockCode: 42,
            unlockCount: 7,
            algorithmParameters: LibreWatchAlgorithmParameters(
                slopeSlope: 0.00001,
                slopeOffset: -0.001,
                offsetSlope: 0.1,
                offsetOffset: -20,
                extraSlope: 1,
                extraOffset: 0,
                sensorSerialNumber: "TEST123456"
            )
        )
    }

    private static func testSessionSerializationAndValidation() throws {
        let original = makeSession()
        try expect(original.isValid, "A complete C6 test session must validate")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LibreWatchTestSession.self, from: encoded)
        try expect(decoded == original, "The versioned Watch session must round-trip")

        let unsupported = LibreWatchTestSession(
            sensorUID: original.sensorUID,
            patchInfo: original.patchInfo,
            sensorSerialNumber: original.sensorSerialNumber,
            sensorTypeRawValue: "E7",
            expectedPeripheralName: original.expectedPeripheralName,
            unlockCode: original.unlockCode,
            unlockCount: original.unlockCount,
            algorithmParameters: original.algorithmParameters
        )
        try expect(
            unsupported.validationError == .unsupportedSensorType,
            "Only the targeted European Libre 2 Plus C6/7F types may validate"
        )
    }

    private static func testIdentityMatching() throws {
        let c6 = makeSession()
        try expect(c6.matches(candidateName: "ABBOTTTEST123456"), "C6 must match ABBOTT + NFC serial")
        try expect(!c6.matches(candidateName: "ABBOTTOTHER12345"), "C6 must reject another nearby sensor")
        try expect(!c6.matches(candidateName: nil), "A missing advertised identity must not match")

        let sevenF = makeSession(sensorType: "7F", expectedName: "A1B2C3D4E5F6")
        try expect(sevenF.isValid, "A 7F session with NFC-derived MAC must validate")
        try expect(sevenF.matches(candidateName: "A1B2C3D4E5F6"), "7F must match its NFC-derived identity")
        try expect(!sevenF.matches(candidateName: "A1B2C3D4E500"), "7F must reject a different MAC identity")
    }

    private static func testOwnershipTransitions() throws {
        try expect(LibreWatchTestOwnership.iphone.canTransition(to: .releasingToWatch), "iPhone must release before Watch ownership")
        try expect(LibreWatchTestOwnership.releasingToWatch.canTransition(to: .watch), "Release acknowledgement must permit Watch ownership")
        try expect(LibreWatchTestOwnership.watch.canTransition(to: .releasingToPhone), "Watch must release before returning to phone")
        try expect(LibreWatchTestOwnership.releasingToPhone.canTransition(to: .iphone), "Return acknowledgement must restore iPhone ownership")
        try expect(!LibreWatchTestOwnership.iphone.canTransition(to: .watch), "Ownership must never jump directly from iPhone to Watch")
    }

    private static func testLibreUUIDDefinitions() throws {
        try expect(Libre2DirectConstants.serviceUUIDString == "FDE3", "Libre service UUID changed")
        try expect(Libre2DirectConstants.writeCharacteristicUUIDString == "F001", "Libre control UUID changed")
        try expect(Libre2DirectConstants.receiveCharacteristicUUIDString == "F002", "Libre receive UUID changed")
        try expect(Libre2DirectConstants.encryptedFrameLength == 46, "Libre encrypted frame length changed")
    }

    private static func testFrameAssembly() throws {
        var assembler = Libre2DirectFrameAssembler()
        let start = Date(timeIntervalSince1970: 2_000)
        let partial = try assembler.append(fragment: Data(repeating: 1, count: 20), at: start)
        try expect(partial == nil, "A partial frame must not complete")
        let frame = try assembler.append(fragment: Data(repeating: 2, count: 26), at: start.addingTimeInterval(1))
        try expect(frame?.count == 46, "Fragments must complete at exactly 46 bytes")
        try expect(assembler.fragmentCount == 2, "Fragment diagnostics must aggregate")
        try expect(assembler.completeFrameCount == 1, "Complete-frame diagnostics must aggregate")

        do {
            _ = try assembler.append(fragment: Data(repeating: 3, count: 47), at: start.addingTimeInterval(2))
            throw DirectTestFailure.failed("An oversized frame must be rejected")
        } catch let error as Libre2DirectAlgorithmError {
            try expect(
                error == .badEncryptedFrameLength(47),
                "An oversized frame must report its exact invalid length"
            )
        }
    }

    private static func testUnlockCounterInput() throws {
        let session = makeSession()
        let first = Libre2DirectAlgorithms.streamingUnlockPayload(
            sensorUID: session.sensorUID,
            patchInfo: session.patchInfo,
            enableTime: session.unlockCode,
            unlockCount: session.unlockCount
        )
        let second = Libre2DirectAlgorithms.streamingUnlockPayload(
            sensorUID: session.sensorUID,
            patchInfo: session.patchInfo,
            enableTime: session.unlockCode,
            unlockCount: session.unlockCount + 1
        )
        try expect(first.count == 12, "The proven streaming unlock payload must remain 12 bytes")
        try expect(Array(first.prefix(4)) == [49, 0, 0, 0], "Unlock time must use code + counter in little-endian order")
        try expect(first != second, "Incrementing the unlock counter must change the payload")
    }

    private static func testIPhoneParserFallback() throws {
        let session = makeSession()
        var decryptedFrame = Data(repeating: 0, count: Libre2DirectConstants.decryptedFrameLength)
        decryptedFrame[0] = 30
        decryptedFrame[4] = 30
        decryptedFrame[40] = 100

        let reading = try Libre2DirectAlgorithms.parseDirectReading(
            decryptedData: decryptedFrame,
            parameters: session.algorithmParameters,
            receivedAt: Date(timeIntervalSince1970: 2_500)
        )

        try expect(
            abs(reading.glucoseMGDL - (30 * ConstantsBloodGlucose.libreMultiplier)) < 0.000_001,
            "Watch parsing and its raw-value limit must match the iPhone parser fallback"
        )
    }

    private static func testDirectSourceGuarantee() throws {
        let watchReading = Libre2DirectReading(
            glucoseMGDL: 123,
            trendMGDLPerMinute: 1,
            sensorTimeInMinutes: 100,
            receivedAt: Date(timeIntervalSince1970: 3_000),
            source: .watchSensorF002
        )
        let phoneReading = Libre2DirectReading(
            glucoseMGDL: 123,
            trendMGDLPerMinute: 1,
            sensorTimeInMinutes: 100,
            receivedAt: Date(timeIntervalSince1970: 3_000),
            source: .iphoneWatchConnectivity
        )
        try expect(watchReading.canDisplayDirectFromSensor, "A Watch F002 reading may be labeled direct")
        try expect(!phoneReading.canDisplayDirectFromSensor, "A WatchConnectivity reading must never be labeled direct")

        var state = LibreWatchDirectState()
        state.recordDirectReading(phoneReading)
        try expect(!state.canDisplayDirectFromSensor, "The direct UI state must reject an iPhone reading")
        state.recordDirectReading(watchReading)
        try expect(state.canDisplayDirectFromSensor, "The direct UI state must accept a Watch F002 reading")
    }

    private static func testStateTimeoutAndFailures() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        var state = LibreWatchDirectState()
        state.sessionAvailable(makeSession())
        state.start(at: start)
        try expect(!state.updateElapsed(at: start.addingTimeInterval(299)), "The foreground test must continue before five minutes")
        try expect(state.updateElapsed(at: start.addingTimeInterval(300)), "The foreground test must stop at five minutes")
        state.fail(.serviceNotFound, error: "Service discovery completed without FDE3")
        try expect(state.stage == .failed, "A major Bluetooth failure must enter failed state")
        try expect(state.failure == .serviceNotFound, "The exact diagnostic failure must be retained")
    }
}
