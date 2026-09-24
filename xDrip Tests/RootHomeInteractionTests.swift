//
//  RootHomeInteractionTests.swift
//  xdripTests
//
//  Created by Paul Plant on 9/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

final class RootHomeInteractionTests: XCTestCase {

    func testIPadLayoutClassRespondsToWindowWidth() {
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: false, width: 1_366, usesAccessibilityText: false), .compact)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 500, usesAccessibilityText: false), .compact)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 744, usesAccessibilityText: false), .regular)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 1_024, usesAccessibilityText: false), .wide)
    }

    func testIPadLayoutClassUsesCompactCompositionForAccessibilityText() {
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 1_366, usesAccessibilityText: true), .compact)
    }

    func testIPadOrientationPolicyAllowsAllTabsToRotate() {
        XCTAssertEqual(
            RootOrientationPolicy.supportedOrientations(isPad: true, isHome: false, allowsHomeRotation: false),
            .all
        )
        XCTAssertEqual(
            RootOrientationPolicy.supportedOrientations(isPad: false, isHome: false, allowsHomeRotation: true),
            .portrait
        )
    }

    func testChartRangesStepShorterWithoutWrapping() {
        XCTAssertNil(RootHomeChartRange.threeHours.nextShorterRange)
        XCTAssertEqual(RootHomeChartRange.fiveHours.nextShorterRange, .threeHours)
        XCTAssertEqual(RootHomeChartRange.eightHours.nextShorterRange, .fiveHours)
        XCTAssertEqual(RootHomeChartRange.twelveHours.nextShorterRange, .eightHours)
        XCTAssertEqual(RootHomeChartRange.twentyFourHours.nextShorterRange, .twelveHours)
    }

    func testChartRangesStepLongerWithoutWrapping() {
        XCTAssertEqual(RootHomeChartRange.threeHours.nextLongerRange, .fiveHours)
        XCTAssertEqual(RootHomeChartRange.fiveHours.nextLongerRange, .eightHours)
        XCTAssertEqual(RootHomeChartRange.eightHours.nextLongerRange, .twelveHours)
        XCTAssertEqual(RootHomeChartRange.twelveHours.nextLongerRange, .twentyFourHours)
        XCTAssertNil(RootHomeChartRange.twentyFourHours.nextLongerRange)
    }

    func testStatisticsPeriodOptionsUseFullLocalizedLabels() {
        XCTAssertEqual(RootHomeStatisticsPeriod.options, [0, 1, 7, 30, 90])
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 0), Texts_Common.today)
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 1), "1 \(Texts_Common.day)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 7), "7 \(Texts_Common.days)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 30), "30 \(Texts_Common.days)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 90), "90 \(Texts_Common.days)")
    }

    func testCareLinkSensorIndicatorUsesHomeLifetimeThresholds() {
        let expired = ConstantsHomeView.careLinkSensorIndicator(remainingMinutes: 0)
        let urgent = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewUrgentInMinutes)
        )
        let warning = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewWarningInMinutes)
        )
        let normal = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewWarningInMinutes) + 1
        )

        XCTAssertEqual(expired.systemImage, "sensor.tag.radiowaves.forward.fill")
        XCTAssertEqual(urgent.systemImage, expired.systemImage)
        XCTAssertEqual(warning.systemImage, expired.systemImage)
        XCTAssertEqual(normal.systemImage, expired.systemImage)
        XCTAssertEqual(expired.color, ConstantsAppColors.sensorExpired)
        XCTAssertEqual(urgent.color, ConstantsAppColors.sensorUrgent)
        XCTAssertEqual(warning.color, ConstantsAppColors.sensorWarning)
        XCTAssertEqual(normal.color, .green)
    }

    func testBatteryIndicatorMatchesLoopStatusBuckets() {
        XCTAssertNil(ConstantsHomeView.batteryIndicator(percent: nil))
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 10)?.color, ConstantsAppColors.urgent)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 11)?.color, ConstantsAppColors.warning)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 26)?.color, ConstantsAppColors.secondaryText)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 66)?.color, ConstantsAppColors.secondaryText)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 91)?.color, ConstantsAppColors.secondaryText)

        if #available(iOS 17.0, *) {
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 10)?.systemImage, "battery.0percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 11)?.systemImage, "battery.25percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 26)?.systemImage, "battery.50percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 66)?.systemImage, "battery.75percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 91)?.systemImage, "battery.100percent")
        }
    }

    @MainActor
    func testHistoricalCacheCompletionDoesNotChaseNowEvenWithEmptyHistory() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        cache.prepare(around: driver.now.addingTimeInterval(-300), visibleTimeInterval: .hours(3))

        // Exercise the original failure path: the buffered end is capped at "now", and time
        // advances while the real Core Data fetch is outstanding. No new request is made.
        driver.now.addTimeInterval(1)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.clockReads, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0, "Completion must not enqueue a newer tail")
        driver.now.addTimeInterval(.hours(24))
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheCoalescesRequestsAndFinishesBothEdgesWithoutMovingNow() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let center = driver.now.addingTimeInterval(-300)
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        // Only the latest pending request matters; it expands both ends of the first load.
        driver.now.addTimeInterval(10)
        cache.prepare(around: center, visibleTimeInterval: .hours(5))
        driver.now.addTimeInterval(10)
        cache.prepare(around: center, visibleTimeInterval: .hours(6))
        XCTAssertEqual(driver.pendingLoads.count, 1)

        for expectedRevision in 1 ... 3 {
            driver.now.addTimeInterval(60)
            try driver.runNextLoad()
            await drainHistoricalCacheCompletions()
            XCTAssertEqual(cache.revision, expectedRevision)
            XCTAssertEqual(driver.pendingLoads.count, expectedRevision < 3 ? 1 : 0)
        }
        XCTAssertEqual(driver.clockReads, 3, "Only external requests may read the clock")
    }

    @MainActor
    func testHistoricalCacheLaterExplicitRequestCanLoadNewStatusAndSiteChange() async throws {
        let driver = HistoricalCacheDriver()
        let initialNow = driver.now
        let center = initialNow.addingTimeInterval(-300)
        let oldSite = center.addingTimeInterval(-.hours(24))
        try driver.storeSiteChange(at: oldSite)
        try await driver.storeStatus(at: center, reservoir: 80)
        let cache = driver.makeCache()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 80)
        XCTAssertEqual(cache.selection(at: center).siteChangeDate, oldSite)

        driver.now.addTimeInterval(60)
        let newSite = initialNow.addingTimeInterval(30)
        try driver.storeSiteChange(at: newSite)
        try await driver.storeStatus(at: driver.now, reservoir: 79)
        XCTAssertEqual(driver.pendingLoads.count, 0, "Database changes alone do not start a loop")
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        driver.now.addTimeInterval(10)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        let selection = cache.selection(at: initialNow.addingTimeInterval(60))
        XCTAssertEqual(selection.deviceStatus?.pumpReservoir, 79)
        XCTAssertEqual(selection.siteChangeDate, newSite)
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 80)
        XCTAssertEqual(cache.revision, 2)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheNavigationBackAndForwardPreservesStoredSelections() async throws {
        let driver = HistoricalCacheDriver()
        let earlier = driver.now.addingTimeInterval(-.hours(8))
        let later = driver.now.addingTimeInterval(-.hours(1))
        try await driver.storeStatus(at: earlier, reservoir: 90)
        try await driver.storeStatus(at: later, reservoir: 80)
        let cache = driver.makeCache()

        for (index, point) in [(later, 80.0), (earlier, 90.0), (later, 80.0)].enumerated() {
            cache.prepare(around: point.0, visibleTimeInterval: .hours(3))
            try driver.runNextLoad()
            await drainHistoricalCacheCompletions()
            XCTAssertEqual(cache.selection(at: point.0).deviceStatus?.pumpReservoir, point.1)
            XCTAssertEqual(cache.revision, index + 1)
            XCTAssertEqual(driver.pendingLoads.count, 0)
        }
    }

    @MainActor
    func testHistoricalCacheCoveredHistoricalRangeDoesNotReloadAsClockAdvances() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let center = driver.now.addingTimeInterval(-.hours(8))
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        driver.now.addTimeInterval(.hours(1))
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        // A smaller, nested request is covered too, including a negative chart interval.
        cache.prepare(around: center, visibleTimeInterval: -.hours(1))
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheResetRejectsQueuedCompletionWithoutDisturbingNewLoad() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let oldCenter = driver.now.addingTimeInterval(-.hours(8))
        let newCenter = driver.now.addingTimeInterval(-300)
        try await driver.storeStatus(at: newCenter, reservoir: 70)
        cache.prepare(around: oldCenter, visibleTimeInterval: .hours(3))
        try driver.runNextLoad() // Real fetch finished; its main-queue completion has not run.
        cache.reset()
        cache.prepare(around: newCenter, visibleTimeInterval: .hours(3))
        await drainHistoricalCacheCompletions()

        XCTAssertEqual(cache.revision, 1, "The old completion must not publish")
        XCTAssertEqual(driver.pendingLoads.count, 1)
        cache.prepare(around: newCenter, visibleTimeInterval: .hours(3))
        XCTAssertEqual(driver.pendingLoads.count, 1, "The new load must still be marked in-flight")
        driver.now.addTimeInterval(60)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 2)
        XCTAssertEqual(driver.pendingLoads.count, 0)
        XCTAssertEqual(cache.selection(at: newCenter).deviceStatus?.pumpReservoir, 70)
    }

    @MainActor
    func testHistoricalCacheBackfillResetReloadsSameRangeFromPersistentHistory() async throws {
        let driver = HistoricalCacheDriver()
        let center = driver.now.addingTimeInterval(-.hours(8))
        let cache = driver.makeCache()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertNil(cache.selection(at: center).deviceStatus)

        // Use the same reset/prepare sequence as RootHomeView's historical-data notifications.
        let site = center.addingTimeInterval(-60)
        try driver.storeSiteChange(at: site)
        try await driver.storeStatus(at: center, reservoir: 60)
        cache.reset()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 60)
        XCTAssertEqual(cache.selection(at: center).siteChangeDate, site)
        XCTAssertEqual(cache.revision, 3)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheCleanupInvalidatesOutstandingLoadWithoutStartingAnother() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        cache.prepare(around: driver.now.addingTimeInterval(-300), visibleTimeInterval: .hours(3))
        // The test scheduler deliberately delivers even cancelled work to exercise generation
        // rejection, as with a real OperationQueue job already running when cleanup occurs.
        cache.cleanUpMemory()
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    private func drainHistoricalCacheCompletions() async {
        // FIFO barrier after the production DispatchQueue.main.async completion, not a sleep.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// Controls only clock/execution order. Queries, range selection, merging, invalidation and
/// main-queue completion all use RootHomeHistoricalDataCache and the real in-memory Core Data store.
@MainActor
private final class HistoricalCacheDriver {
    let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var clockReads = 0
    var pendingLoads = [() -> Void]()

    func makeCache() -> RootHomeHistoricalDataCache {
        RootHomeHistoricalDataCache(
            coreDataManager: stack,
            now: {
                self.clockReads += 1
                return self.now
            },
            scheduleLoad: { self.pendingLoads.append($0) }
        )
    }

    func runNextLoad() throws {
        XCTAssertEqual(pendingLoads.count, 1, "No parallel cache loads")
        let load = try XCTUnwrap(pendingLoads.first)
        pendingLoads.removeFirst()
        load()
    }

    func storeStatus(at date: Date, reservoir: Double) async throws {
        var status = NightscoutDeviceStatus()
        status.id = "cache-test-\(date.timeIntervalSince1970)"
        status.createdAt = date
        status.updatedDate = date
        status.lastCheckedDate = date
        status.lastLoopDate = date
        status.pumpReservoir = reservoir
        let saved = await NightscoutDeviceStatusAccessor(coreDataManager: stack).upsert(status)
        XCTAssertTrue(saved)
    }

    func storeSiteChange(at date: Date) throws {
        let context = stack.privateManagedObjectContext
        try context.performAndWait {
            _ = TreatmentEntry(
                date: date, value: 0, treatmentType: .SiteChange,
                nightscoutEventType: "Site Change", enteredBy: nil,
                nsManagedObjectContext: context
            )
            try context.save()
        }
    }
}

final class RootHomeStatisticsEasterEggTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 16, minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func easterEgg(_ date: Date, days: Int = 0, low: Double = 0, inRange: Double = 100,
                            high: Double = 0, enabled: Bool = true) -> RootHomeStatisticsEasterEgg? {
        RootHomeStatisticsEasterEggPolicy.easterEgg(low: low, inRange: inRange, high: high,
            days: days, now: date, calendar: calendar, enabled: enabled)
    }

    func testRequiresExactInRangeData() {
        let now = date(9, 10)
        XCTAssertEqual(easterEgg(now), .sunglasses)
        XCTAssertNil(easterEgg(now, low: 0.1, inRange: 99.9))
        XCTAssertNil(easterEgg(now, inRange: 99.9, high: 0.1))
        XCTAssertNil(easterEgg(now, inRange: 0))
        XCTAssertNil(easterEgg(now, inRange: .nan))
        XCTAssertNil(easterEgg(now, enabled: false))
    }

    func testTodayThresholdAndMidnight() {
        XCTAssertNil(easterEgg(date(9, 10, hour: 15, minute: 59)))
        XCTAssertEqual(easterEgg(date(9, 10)), .sunglasses)
        XCTAssertEqual(easterEgg(date(9, 10, hour: 23, minute: 59)), .sunglasses)
        XCTAssertNil(easterEgg(date(9, 11, hour: 0)))
        for days in [1, 7, 30, 90] {
            XCTAssertEqual(easterEgg(date(9, 10, hour: 0), days: days), .sunglasses)
        }
    }

    func testSeasonalDatesAndAdjacentDays() {
        for (month, day, expected) in [
            (1, 1, RootHomeStatisticsEasterEgg.newYear),
            (1, 2, .sunglasses),
            (10, 30, .sunglasses), (10, 31, .halloween), (11, 1, .sunglasses),
            (12, 22, .sunglasses), (12, 23, .christmas), (12, 31, .christmas)
        ] {
            XCTAssertEqual(easterEgg(date(month, day)), expected)
            XCTAssertNil(easterEgg(date(month, day, hour: 15)))
            XCTAssertEqual(easterEgg(date(month, day, hour: 0), days: 7), expected)
        }
        XCTAssertEqual(easterEgg(date(1, 1, year: 2027), days: 7), .newYear)
    }

    func testThresholdUsesWallClockAcrossDaylightSavingChanges() {
        for (month, day) in [(3, 29), (10, 25)] {
            XCTAssertNil(easterEgg(date(month, day, hour: 15, minute: 59)))
            XCTAssertEqual(easterEgg(date(month, day)), .sunglasses)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(RootHomeStatisticsEasterEggPolicy.easterEgg(low: 0, inRange: 100, high: 0,
            days: 0, now: date(9, 10), calendar: utc))
    }

    func testLoadingClearsEasterEggAndTimeRefreshDoesNotRestoreIt() {
        let model = RootHomeStateModel()
        model.updateStatistics(StatisticsManager.Statistics(lowStatisticValue: 0, highStatisticValue: 0,
            inRangeStatisticValue: 100, averageStatisticValue: 100, gmiPercentage: 5,
            cVStatisticValue: 0, lowLimitForTIR: 70, highLimitForTIR: 180, numberOfDaysUsed: 1))
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .sunglasses)
        model.setStatisticsLoading()
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
    }

    func testTimeRefreshHandlesForegroundReturnAndSeasonChange() {
        let model = RootHomeStateModel()
        model.updateStatistics(StatisticsManager.Statistics(lowStatisticValue: 0, highStatisticValue: 0,
            inRangeStatisticValue: 100, averageStatisticValue: 100, gmiPercentage: 5,
            cVStatisticValue: 0, lowLimitForTIR: 70, highLimitForTIR: 180, numberOfDaysUsed: 1))
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10, hour: 15), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .sunglasses)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 11, hour: 0), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 7, now: date(12, 31), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .christmas)
        model.updateStatisticsEasterEgg(days: 7, now: date(1, 1, hour: 0, year: 2027), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .newYear)
    }

    func testRequestContextRejectsChangedPeriodRangeDayAndTimeZone() {
        func context(days: Int = 0, range: Int = 0, low: Double = 70, high: Double = 180,
                     now: Date, calendar: Calendar) -> RootHomeStatisticsContext {
            RootHomeStatisticsContext(days: days, range: range, lowLimit: low, highLimit: high,
                isMgDl: true, now: now, calendar: calendar)
        }
        let now = date(9, 10)
        let original = context(now: now, calendar: calendar)
        XCTAssertEqual(original, context(now: date(9, 10, hour: 23), calendar: calendar))
        XCTAssertNotEqual(original, context(now: date(9, 11, hour: 0), calendar: calendar))
        XCTAssertNotEqual(original, context(days: 7, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(range: 1, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(high: 140, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(low: 80, now: now, calendar: calendar))
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNotEqual(original, context(now: now, calendar: utc))
        XCTAssertEqual(context(days: 7, now: now, calendar: calendar),
                       context(days: 7, now: date(9, 11), calendar: calendar))
    }
}
