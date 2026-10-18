import XCTest
import SwiftUI
import WidgetKit
@testable import xdrip

// The test target compiles the actual widget Entry and Provider source files.
// Only the namespace is supplied here; no storage, timeline or presentation logic is copied.
enum XDripWidget {}

final class WidgetPresentationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let bundleID = "WidgetPresentationTests.synthetic"

    private func defaults() -> UserDefaults {
        let suite = "WidgetPresentationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func provider(_ defaults: UserDefaults?, at date: Date? = nil) -> XDripWidget.Provider {
        let capturedDate = date ?? self.date
        return XDripWidget.Provider(sharedUserDefaults: defaults,
                                    mainAppBundleIdentifier: bundleID, currentDate: { capturedDate })
    }

    private func payload(isMgDl: Bool = true) -> WidgetSharedUserDefaultsModel {
        WidgetSharedUserDefaultsModel(bgReadingValues: [126, 120],
            bgReadingDatesAsDouble: [date.timeIntervalSince1970, date.addingTimeInterval(-300).timeIntervalSince1970],
            isMgDl: isMgDl, slopeOrdinal: 3, deltaValueInUserUnit: isMgDl ? 6 : 0.3,
            urgentLowLimitInMgDl: 55, lowLimitInMgDl: 75, highLimitInMgDl: 155, urgentHighLimitInMgDl: 220,
            dataSourceDescription: "Synthetic source", followerPatientName: "Synthetic follower",
            allowStandByHighContrast: false, forceStandByBigNumbers: true)
    }

    private func save(_ payload: WidgetSharedUserDefaultsModel, to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(payload),
                     forKey: WidgetSharedUserDefaultsModel.widgetDataKey(for: bundleID))
    }

    private func assertEmpty(_ entry: XDripWidget.Entry, message: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        let state = entry.widgetState
        XCTAssertTrue(state.bgReadingValues?.isEmpty ?? true, file: file, line: line)
        XCTAssertTrue(state.bgReadingDates?.isEmpty ?? true, file: file, line: line)
        XCTAssertNil(state.bgValueInMgDl, file: file, line: line)
        XCTAssertNil(state.bgReadingDate, file: file, line: line)
        XCTAssertEqual(state.bgValueStringInUserChosenUnit(at: entry.date), state.isMgDl ? "---" : "-.-", file: file, line: line)
        XCTAssertEqual(state.trendArrow(at: entry.date), "", file: file, line: line)
        XCTAssertNil(state.gaugeModel(at: entry.date).value, file: file, line: line)
        XCTAssertEqual(state.keepAliveDisabledMessage, message, file: file, line: line)
    }

    func testPreviewUsesSampleButRealSnapshotUsesOnlyStoredPayload() throws {
        let defaults = defaults()
        let data = payload(isMgDl: false)
        try save(data, to: defaults)
        let provider = provider(defaults)
        let preview = provider.snapshot(isPreview: true)
        XCTAssertEqual(preview.widgetState.bgReadingValues, ConstantsWidgetExtension.bgReadingValuesPlaceholderData)
        XCTAssertEqual(preview.widgetState.bgReadingDate, date)
        XCTAssertEqual(preview.date, date)

        let real = provider.snapshot(isPreview: false)
        XCTAssertEqual(real.widgetState.bgReadingValues, data.bgReadingValues)
        XCTAssertEqual(real.widgetState.bgReadingDates?.map(\.timeIntervalSince1970), data.bgReadingDatesAsDouble)
        XCTAssertEqual(real.date, date)
        XCTAssertFalse(real.widgetState.isMgDl)
        XCTAssertEqual(real.widgetState.deltaValueInUserUnit, 0.3)
        XCTAssertEqual(real.widgetState.slopeOrdinal, 3)
        XCTAssertEqual(real.widgetState.urgentLowLimitInMgDl, 55)
        XCTAssertEqual(real.widgetState.lowLimitInMgDl, 75)
        XCTAssertEqual(real.widgetState.highLimitInMgDl, 155)
        XCTAssertEqual(real.widgetState.urgentHighLimitInMgDl, 220)
        XCTAssertFalse(real.widgetState.allowStandByHighContrast)
        XCTAssertTrue(real.widgetState.forceStandByBigNumbers)
        XCTAssertEqual(real.widgetState.followerPatientName, data.followerPatientName)
        XCTAssertEqual(real.widgetState.dataSourceDescription, data.dataSourceDescription)
    }

    func testMissingUnreadableAndUnavailableStorageNeverCreateSampleReadings() {
        let defaults = defaults()
        let message = "Synthetic keep-alive message"
        defaults.set(message, forKey: WidgetSharedUserDefaultsModel.keepAliveDisabledMessageKey(for: bundleID))
        assertEmpty(provider(defaults).snapshot(isPreview: false), message: message)
        assertEmpty(provider(defaults).timeline().entries[0], message: message)
        defaults.set(Data("not JSON".utf8), forKey: WidgetSharedUserDefaultsModel.widgetDataKey(for: bundleID))
        assertEmpty(provider(defaults).snapshot(isPreview: false), message: message)
        assertEmpty(provider(defaults).timeline().entries[0], message: message)
        assertEmpty(provider(nil).snapshot(isPreview: false))
        XCTAssertEqual(provider(nil).timeline().entries.count, 1)
        XCTAssertFalse(provider(nil).snapshot(isPreview: true).widgetState.bgReadingValues?.isEmpty ?? true)
    }

    func testEmptyPayloadPreservesUserUnitsAndOptionsAndMalformedPairsStayEmpty() throws {
        let defaults = defaults()
        var data = payload(isMgDl: false)
        data.bgReadingValues = []
        data.bgReadingDatesAsDouble = []
        try save(data, to: defaults)
        let empty = provider(defaults).snapshot(isPreview: false)
        assertEmpty(empty)
        XCTAssertFalse(empty.widgetState.isMgDl)
        XCTAssertFalse(empty.widgetState.allowStandByHighContrast)
        XCTAssertTrue(empty.widgetState.forceStandByBigNumbers)
        XCTAssertEqual(empty.widgetState.lowLimitInMgDl, 75)
        XCTAssertEqual(provider(defaults).timeline().entries.count, 1)

        data.bgReadingValues = [126]
        try save(data, to: defaults)
        assertEmpty(provider(defaults).snapshot(isPreview: false))
    }

    func testTimelineAgesUnchangedReadingsAtExactSevenAndTwentyMinuteBoundaries() throws {
        let defaults = defaults()
        try save(payload(), to: defaults)
        let entries = provider(defaults).timeline().entries
        XCTAssertEqual(entries.map(\.date), [date, date.addingTimeInterval(7 * 60), date.addingTimeInterval(20 * 60)])
        for entry in entries {
            XCTAssertEqual(entry.widgetState.bgReadingValues, [126, 120])
            XCTAssertEqual(entry.widgetState.bgReadingDate, date)
        }
        let fresh = entries[0]
        XCTAssertEqual(fresh.widgetState.bgValueStringInUserChosenUnit(at: fresh.date), "126")
        XCTAssertEqual(fresh.widgetState.bgTextColor(at: fresh.date), .green)
        XCTAssertEqual(fresh.widgetState.deltaChangeTextColor(at: fresh.date), .colorPrimary)
        XCTAssertEqual(fresh.widgetState.deltaChangeStringInUserChosenUnit(at: fresh.date), "+6")
        XCTAssertEqual(fresh.widgetState.trendArrow(at: fresh.date), "↗")

        let stale = entries[1]
        XCTAssertEqual(stale.widgetState.bgValueStringInUserChosenUnit(at: stale.date), "126")
        XCTAssertEqual(stale.widgetState.bgTextColor(at: stale.date), .colorTertiary)
        XCTAssertEqual(stale.widgetState.deltaChangeTextColor(at: stale.date), .colorTertiary)
        XCTAssertEqual(stale.widgetState.deltaChangeStringInUserChosenUnit(at: stale.date), "+6")
        XCTAssertEqual(stale.widgetState.trendArrow(at: stale.date), "↗")
        XCTAssertEqual(stale.widgetState.gaugeModel(at: stale.date).gaugeColor, .colorTertiary)
        XCTAssertTrue(stale.widgetState.gaugeModel(at: stale.date).gaugeGradient.stops.allSatisfy { $0.color == .colorTertiary })

        let expired = entries[2]
        XCTAssertEqual(expired.widgetState.bgValueStringInUserChosenUnit(at: expired.date), "---")
        XCTAssertEqual(expired.widgetState.deltaChangeStringInUserChosenUnit(at: expired.date), "-")
        XCTAssertEqual(expired.widgetState.trendArrow(at: expired.date), "")
        XCTAssertNil(expired.widgetState.gaugeModel(at: expired.date).value)
        XCTAssertEqual(expired.widgetState.bgTextColor(at: expired.date), .colorTertiary)
        XCTAssertEqual(fresh.widgetState.bgTextColor(at: stale.date.addingTimeInterval(-0.001)), .green)
        XCTAssertEqual(fresh.widgetState.bgValueStringInUserChosenUnit(at: expired.date.addingTimeInterval(-0.001)), "126")
    }

    func testStaleAndExpiredLoadsOnlyScheduleFutureTransitions() throws {
        let defaults = defaults()
        try save(payload(), to: defaults)
        for minutes in [7.0, 10.0] {
            let start = date.addingTimeInterval(minutes * 60)
            let entries = provider(defaults, at: start).timeline().entries
            XCTAssertEqual(entries.map(\.date), [start, date.addingTimeInterval(20 * 60)])
            XCTAssertFalse(entries[0].widgetState.hasFreshGlucose(at: entries[0].date))
        }
        for minutes in [20.0, 45.0] {
            let start = date.addingTimeInterval(minutes * 60)
            let entries = provider(defaults, at: start).timeline().entries
            XCTAssertEqual(entries.map(\.date), [start])
            XCTAssertEqual(entries[0].widgetState.bgValueStringInUserChosenUnit(at: start), "---")
            XCTAssertNil(entries[0].widgetState.gaugeModel(at: start).value)
        }
    }

    func testTherapyDeadlinesRemainSortedDeduplicatedAndKeepTheirPayload() throws {
        let defaults = defaults()
        var data = payload()
        let metrics = TherapyMetricsSnapshot(
            iob: TherapyMetricState(amount: 1.25, source: .local, referenceDate: date,
                expiresAt: date.addingTimeInterval(7 * 60), visibilityDeadline: date.addingTimeInterval(25 * 60)),
            cob: TherapyMetricState(amount: 12, source: .local, referenceDate: date,
                expiresAt: date.addingTimeInterval(3 * 60), visibilityDeadline: date.addingTimeInterval(30 * 60)))
        data.therapyMetrics = metrics
        try save(data, to: defaults)
        let entries = provider(defaults).timeline().entries
        XCTAssertEqual(entries.map(\.date), [0, 3, 7, 20, 25, 30].map { date.addingTimeInterval(Double($0) * 60) })
        XCTAssertTrue(entries.allSatisfy { $0.widgetState.therapyMetrics == metrics })
        let expired = provider(defaults, at: date.addingTimeInterval(21 * 60)).timeline().entries
        XCTAssertEqual(expired.map(\.date), [21, 25, 30].map { date.addingTimeInterval(Double($0) * 60) })
    }

    func testMmolFormattingAndGaugeRangeKeepUserSettingsAcrossAging() throws {
        let defaults = defaults()
        var data = payload(isMgDl: false)
        data.bgReadingValues[0] = 180
        try save(data, to: defaults)
        let entries = provider(defaults).timeline().entries
        let fresh = entries[0]
        XCTAssertEqual(fresh.widgetState.bgValueStringInUserChosenUnit(at: fresh.date), Double(180).mgDlToMmolAndToString(mgDl: false))
        XCTAssertEqual(fresh.widgetState.deltaChangeStringInUserChosenUnit(at: fresh.date), "+" + Double(0.3).mmolToString())
        XCTAssertEqual(fresh.widgetState.bgTextColor(at: fresh.date), .yellow)
        XCTAssertEqual(fresh.widgetState.gaugeModel(at: fresh.date).value, 180)
        XCTAssertEqual(fresh.widgetState.gaugeModel(at: fresh.date).minValue, 75)
        XCTAssertEqual(fresh.widgetState.gaugeModel(at: fresh.date).maxValue, 220)
        let expired = entries[2]
        XCTAssertEqual(expired.widgetState.bgValueStringInUserChosenUnit(at: expired.date), "-.-")
        XCTAssertEqual(expired.widgetState.deltaChangeStringInUserChosenUnit(at: expired.date), "-.-")
        XCTAssertNil(expired.widgetState.gaugeModel(at: expired.date).value)
        XCTAssertFalse(expired.widgetState.allowStandByHighContrast)
        XCTAssertTrue(expired.widgetState.forceStandByBigNumbers)
    }
}
