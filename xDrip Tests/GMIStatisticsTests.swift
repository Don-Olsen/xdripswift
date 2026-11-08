//
//  GMIStatisticsTests.swift
//  xdripTests
//
//  Created by Paul Plant on 21/09/2026.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Combine
import PDFKit
import XCTest
@testable import xdrip

final class GMIStatisticsTests: XCTestCase {
    func testGMIAndIFCCConversionUseUnroundedValues() {
        let percentage = GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 120)
        XCTAssertEqual(percentage, 6.1804, accuracy: 0.000001)
        XCTAssertEqual(GlucoseReportClinicalMath.gmiValue(7, usesIFCC: true), 53, accuracy: 0.01)
        // Converting a rounded 6.2% instead would incorrectly display 44 mmol/mol.
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.23, usesIFCC: true), "45 mmol/mol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.22, usesIFCC: true), "44 mmol/mol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.22, usesIFCC: true, compactUnit: true), "44 mmol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.22, usesIFCC: false, locale: Locale(identifier: "en_US")), "6.2%")
        XCTAssertEqual(GlucoseReportFormatting.gmi(6.22, usesIFCC: false, locale: Locale(identifier: "es_ES")), "6,2%")
        XCTAssertEqual(GlucoseReportFormatting.gmi(0, usesIFCC: true), "-")
    }

    func testNearbyAveragesCanDisplayTheSameWholeNumberGMI() {
        let first = GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 107)
        let second = GlucoseReportClinicalMath.gmiPercentage(forAverageMgDl: 110)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(GlucoseReportFormatting.gmi(first, usesIFCC: true), "41 mmol/mol")
        XCTAssertEqual(GlucoseReportFormatting.gmi(second, usesIFCC: true), "41 mmol/mol")
    }

    func testChartDomainsContainConvertedValuesAndHaveIntegerIFCCTicks() {
        for percentages in [[], [6.2], [5.1, 6.2, 9.9]] as [[Double]] {
            let domain = GlucoseReportClinicalMath.gmiDomain(percentages: percentages, usesIFCC: true)
            for percentage in percentages {
                XCTAssertTrue(domain.contains(GlucoseReportClinicalMath.gmiValue(percentage, usesIFCC: true)))
            }
            let ticks = [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2, domain.upperBound]
            XCTAssertTrue(ticks.allSatisfy { $0.rounded() == $0 })
            XCTAssertLessThan(domain.lowerBound, domain.upperBound)
        }
        XCTAssertEqual(GlucoseReportClinicalMath.gmiDomain(percentages: [6.2], usesIFCC: false), 6 ... 7)
    }

    @MainActor
    func testHomeSummaryAndTrendShareSamplesAcrossUnitsAndCachedResults() async throws {
        let savedIFCC = UserDefaults.standard.object(forKey: "useIFCCA1C")
        let savedGlucoseUnit = UserDefaults.standard.object(forKey: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue)
        defer {
            UserDefaults.standard.set(savedIFCC, forKey: "useIFCCA1C")
            UserDefaults.standard.set(savedGlucoseUnit, forKey: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: directory.appendingPathComponent("GMI.sqlite"))
        defer {
            try? core.disconnectPersistentStoresForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let end = Date()
        // One-minute data exposes the old Home-only 4.5-minute filter. Its selected values are
        // always 100, whereas the shared population averages 180 mg/dL.
        for index in 0..<60 {
            let value = index % 5 == 0 ? 100.0 : 200.0
            let reading = BgReading(timeStamp: end.addingTimeInterval(Double(index - 120) * 60),
                sensor: nil, calibration: nil, rawData: value, deviceName: "GMI regression",
                nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
        // Suppressed readings must not contribute to either surface.
        let suppressed = BgReading(timeStamp: end.addingTimeInterval(-30 * 60), sensor: nil,
            calibration: nil, rawData: 350, deviceName: "GMI regression",
            nsManagedObjectContext: core.mainManagedObjectContext)
        suppressed.calculatedValue = 350
        suppressed.isSuppressedByFiveMinuteCadence = true
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        let expected = 7.6156
        for usesMgDl in [true, false] {
            UserDefaults.standard.bloodGlucoseUnitIsMgDl = usesMgDl
            for usesIFCC in [false, true] {
                UserDefaults.standard.useIFCCA1C = usesIFCC
                let configuration = GlucoseReportConfiguration(patientName: "GMI regression", patientID: "",
                    period: .seven, aidPeriod: .notIncluded, paperSize: .a4, language: .english,
                    usesIFCC: usesIFCC)
                let analytics = await manager.reportAnalytics(for: configuration)
                let home = await withCheckedContinuation { continuation in
                    manager.calculateStatistics(fromDate: end.addingTimeInterval(-7 * 86400), toDate: end) {
                        continuation.resume(returning: $0)
                    }
                }
                XCTAssertEqual(analytics.sampleCount, 60)
                XCTAssertEqual(home.gmiPercentage, expected, accuracy: 0.000001)
                XCTAssertEqual(home.gmiPercentage, analytics.gmiPercentage, accuracy: 0.000001)
                XCTAssertEqual(try XCTUnwrap(analytics.trendPoints.first).gmiPercentage, expected, accuracy: 0.000001)
                let model = RootHomeStateModel()
                model.updateStatistics(home)
                XCTAssertEqual(model.state.statistics.gmi.title, "GMI")
                XCTAssertEqual(model.state.statistics.gmi.value,
                    GlucoseReportFormatting.gmi(expected, usesIFCC: usesIFCC, compactUnit: true))
                // Home's existing average is intentionally unaffected by GMI sample alignment.
                XCTAssertEqual(home.averageStatisticValue, usesMgDl ? 100 : 100 * ConstantsBloodGlucose.mgDlToMmoll, accuracy: 0.000001)
            }
        }
    }

    @MainActor
    func testSummaryGMIUpdatesWhenChangingAndRevisitingPeriods() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: directory.appendingPathComponent("Periods.sqlite"))
        defer {
            try? core.disconnectPersistentStoresForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let end = Date()
        // Distinct averages in each window make an accidentally static summary unmistakable.
        for day in 0..<90 {
            let value = day < 7 ? 100.0 : day < 30 ? 160.0 : day < 60 ? 200.0 : 240.0
            for hour in 0..<24 {
                let date = end.addingTimeInterval(-Double(day * 86400 + hour * 3600 + 1800))
                let reading = BgReading(timeStamp: date, sensor: nil, calibration: nil,
                    rawData: value, deviceName: "GMI period regression",
                    nsManagedObjectContext: core.mainManagedObjectContext)
                reading.calculatedValue = value
            }
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let viewModel = StatisticsViewModel(statisticsManager: StatisticsManager(coreDataManager: core))
        let cases: [(GlucoseReportPeriod, Double, String, String)] = [
            (.seven, 100, "5.7%", "39 mmol/mol"),
            (.thirty, 146, "6.8%", "51 mmol/mol"),
            (.sixty, 173, "7.4%", "58 mmol/mol"),
            (.ninety, 195.3333333333333, "8.0%", "64 mmol/mol"),
            (.seven, 100, "5.7%", "39 mmol/mol")
        ]
        for (period, expectedAverage, percentageText, ifccText) in cases {
            let loaded = expectation(description: "Summary updated for \(period.rawValue) days")
            var result: GlucoseReportAnalytics?
            let subscription = viewModel.$analytics.compactMap { $0 }
                .first { abs($0.periodEnd.timeIntervalSince($0.periodStart) - Double(period.rawValue * 86400)) < 1 }
                .sink {
                    result = $0
                    loaded.fulfill()
                }
            viewModel.selectedPeriod = period
            await fulfillment(of: [loaded], timeout: 10)
            subscription.cancel()
            let analytics = try XCTUnwrap(result)
            XCTAssertEqual(analytics.sampleCount, period.rawValue * 24)
            XCTAssertEqual(analytics.averageMgDl, expectedAverage, accuracy: 0.000001)
            XCTAssertEqual(analytics.gmiPercentage, 3.31 + 0.02392 * expectedAverage, accuracy: 0.000001)
            XCTAssertEqual(GlucoseReportFormatting.gmi(analytics.gmiPercentage, usesIFCC: false,
                locale: Locale(identifier: "en_US")), percentageText)
            XCTAssertEqual(GlucoseReportFormatting.gmi(analytics.gmiPercentage, usesIFCC: true), ifccText)
        }
    }

    @MainActor
    func testReportSnapshotAndBothPaperSizesRenderInBothUnits() async throws {
        let savedIFCC = UserDefaults.standard.object(forKey: "useIFCCA1C")
        defer { UserDefaults.standard.set(savedIFCC, forKey: "useIFCCA1C") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: directory.appendingPathComponent("Report.sqlite"))
        defer {
            try? core.disconnectPersistentStoresForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        let end = Date()
        for index in 1...2016 {
            let value = 120 + 35 * sin(Double(index) / 50)
            let reading = BgReading(timeStamp: end.addingTimeInterval(-Double(index) * 300),
                sensor: nil, calibration: nil, rawData: value, deviceName: "GMI report regression",
                nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = StatisticsManager(coreDataManager: core)
        for usesIFCC in [false, true] {
            for paperSize in [GlucoseReportPaperSize.a4, .usLetter] {
                let configuration = GlucoseReportConfiguration(
                    patientName: "GMI-QA-\(usesIFCC ? "IFCC" : "Percent")-\(paperSize)", patientID: "Synthetic data",
                    period: .seven, aidPeriod: .notIncluded, paperSize: paperSize, language: .english,
                    usesIFCC: usesIFCC)
                // Changes after capture must not affect the generated report.
                UserDefaults.standard.useIFCCA1C = !usesIFCC
                let analytics = await manager.reportAnalytics(for: configuration)
                let url = try await GlucoseReportPDFGenerator().generatePDF(configuration: configuration,
                    analytics: analytics, generatedAt: end)
                let pdf = try XCTUnwrap(PDFDocument(url: url))
                XCTAssertEqual(pdf.pageCount, 3)
                XCTAssertEqual(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).size, paperSize.pageSize)
                // Keep the rendered report in the test results for visual review.
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.lifetime = .keepAlways
                add(attachment)
                try FileManager.default.removeItem(at: url)
            }
        }
    }


    @MainActor
    func testStatisticsOpeningReusesOneGlucoseWindowAtTheCapturedReference() async throws {
        try await withStatisticsStore { core in
            let end = Date(timeIntervalSince1970: 1_800_000_000)
            let start = end.addingTimeInterval(-7 * 86400)
            _ = self.addStatisticsReading(core, at: start.addingTimeInterval(-1), value: 260)
            _ = self.addStatisticsReading(core, at: start, value: 240)
            _ = self.addStatisticsReading(core, at: start.addingTimeInterval(1), value: 100)
            _ = self.addStatisticsReading(core, at: end.addingTimeInterval(-1), value: 140)
            _ = self.addStatisticsReading(core, at: end, value: 220)
            _ = self.addStatisticsReading(core, at: end.addingTimeInterval(1), value: 280)
            let suppressed = self.addStatisticsReading(core, at: end.addingTimeInterval(-60), value: 350)
            suppressed.isSuppressedByFiveMinuteCadence = true
            _ = self.addStatisticsReading(core, at: end.addingTimeInterval(-120), value: 0)
            XCTAssertTrue(core.saveChangesSynchronously())

            let manager = StatisticsManager(coreDataManager: core)
            let fetches = StatisticsFetchProbe()
            manager.glucoseFetchObserver = { fetches.record(start: $0, end: $1) }
            let availability = await manager.availableReportPeriods(referenceDate: end)
            XCTAssertEqual(availability[.seven], false)
            let configuration = self.statisticsConfiguration(period: .seven)
            let cached = await manager.reportAnalytics(for: configuration, referenceDate: end)
            // A separate real manager gives the original direct SQLite population for comparison.
            let direct = await StatisticsManager(coreDataManager: core)
                .reportAnalytics(for: configuration, referenceDate: end)
            XCTAssertEqual(fetches.windows.count, 1)
            XCTAssertEqual(fetches.windows.first?.end, end)
            XCTAssertEqual(cached.periodEnd, end)
            XCTAssertEqual(cached.periodStart, start)
            XCTAssertEqual(cached.sampleCount, 2)
            XCTAssertEqual(cached.sampleCount, direct.sampleCount)
            XCTAssertEqual(cached.firstReading, direct.firstReading)
            XCTAssertEqual(cached.lastReading, direct.lastReading)
            XCTAssertEqual(cached.averageMgDl, 120, accuracy: 0.000001)
            XCTAssertEqual(cached.averageMgDl, direct.averageMgDl, accuracy: 0.000001)
            XCTAssertEqual(cached.gmiPercentage, direct.gmiPercentage, accuracy: 0.000001)
            XCTAssertEqual(cached.coefficientOfVariation, direct.coefficientOfVariation, accuracy: 0.000001)
        }
    }

    @MainActor
    func testStatisticsSharedWindowInvalidatesAfterInsertEditAndDelete() async throws {
        try await withStatisticsStore { core in
            let end = Date(timeIntervalSince1970: 1_800_000_000)
            let first = self.addStatisticsReading(core, at: end.addingTimeInterval(-600), value: 100)
            let second = self.addStatisticsReading(core, at: end.addingTimeInterval(-300), value: 140)
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = StatisticsManager(coreDataManager: core)
            let fetches = StatisticsFetchProbe()
            manager.glucoseFetchObserver = { fetches.record(start: $0, end: $1) }
            let configuration = self.statisticsConfiguration(period: .seven)

            for (step, count, average) in [(0, 2, 120.0), (1, 3, 140.0), (2, 3, 180.0), (3, 2, 200.0)] {
                if step == 1 {
                    _ = self.addStatisticsReading(core, at: end.addingTimeInterval(-60), value: 180)
                } else if step == 2 {
                    first.calculatedValue = 220
                } else if step == 3 {
                    core.mainManagedObjectContext.delete(second)
                }
                if step > 0 { XCTAssertTrue(core.saveChangesSynchronously()) }
                _ = await manager.availableReportPeriods(referenceDate: end)
                let analytics = await manager.reportAnalytics(for: configuration, referenceDate: end)
                XCTAssertEqual(analytics.sampleCount, count, "Mutation step \(step)")
                XCTAssertEqual(analytics.averageMgDl, average, accuracy: 0.000001, "Mutation step \(step)")
                XCTAssertEqual(fetches.windows.count, step + 1,
                    "Each committed mutation needs one fresh window, not one fetch per consumer")
            }
        }
    }

    @MainActor
    func testStatisticsRepeatedOpeningWithInsufficientSevenDayDataFinishesLoading() async throws {
        try await withStatisticsStore { core in
            let end = Date(timeIntervalSince1970: 1_800_000_000)
            _ = self.addStatisticsReading(core, at: end.addingTimeInterval(-300), value: 120)
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = StatisticsManager(coreDataManager: core)
            let model = StatisticsViewModel(statisticsManager: manager, now: { end })
            var publications = [GlucoseReportAnalytics]()
            let subscription = model.$analytics.compactMap { $0 }.sink { publications.append($0) }
            defer { subscription.cancel() }

            await self.completeStatisticsLoad(model)
            XCTAssertEqual(model.selectedPeriod, .seven)
            XCTAssertFalse(model.isPeriodAvailable(.seven))
            XCTAssertEqual(publications.count, 1)
            await self.completeStatisticsLoad(model)
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(publications.count, 2, "An unchanged fallback still completes a new load")
            XCTAssertEqual(model.analytics?.sampleCount, 1)
            XCTAssertEqual(model.analytics?.periodEnd, end)
        }
    }

    @MainActor
    func testStatisticsChangedFallbackPublishesOnceAndUsesOneWindow() async throws {
        try await withStatisticsStore { core in
            let end = Date(timeIntervalSince1970: 1_800_000_000)
            for index in 0..<2016 {
                _ = self.addStatisticsReading(core,
                    at: end.addingTimeInterval(-60 - Double(index) * 300), value: 120)
            }
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = StatisticsManager(coreDataManager: core)
            let fetches = StatisticsFetchProbe()
            manager.glucoseFetchObserver = { fetches.record(start: $0, end: $1) }
            let model = StatisticsViewModel(statisticsManager: manager, now: { end })
            var publications = 0
            let subscription = model.$analytics.compactMap { $0 }.sink { _ in publications += 1 }
            defer { subscription.cancel() }

            XCTAssertEqual(model.selectedPeriod, .ninety)
            await self.completeStatisticsLoad(model)
            XCTAssertEqual(model.selectedPeriod, .seven)
            XCTAssertTrue(model.isPeriodAvailable(.seven))
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(model.analytics?.sampleCount, 2016)
            XCTAssertEqual(model.analytics?.periodEnd, end)
            XCTAssertEqual(fetches.windows.count, 1,
                "Availability, selected analytics and low-warning statistics share the same glucose window")
        }
    }

    @MainActor
    func testStatisticsPDFAnalyticsKeepTheirOwnCurrentCutoffAfterScreenOpening() async throws {
        try await withStatisticsStore { core in
            let current = Date()
            let openingEnd = current.addingTimeInterval(-600)
            _ = self.addStatisticsReading(core, at: current.addingTimeInterval(-900), value: 120)
            _ = self.addStatisticsReading(core, at: current.addingTimeInterval(-60), value: 180)
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = StatisticsManager(coreDataManager: core)
            let configuration = self.statisticsConfiguration(period: .seven)
            _ = await manager.availableReportPeriods(referenceDate: openingEnd)
            let screen = await manager.reportAnalytics(for: configuration, referenceDate: openingEnd)
            XCTAssertEqual(screen.sampleCount, 1)
            XCTAssertEqual(screen.periodEnd, openingEnd)

            // The existing PDF consumer calls this API without the screen's explicit cutoff.
            let report = await manager.reportAnalytics(for: configuration)
            XCTAssertGreaterThan(report.periodEnd, openingEnd)
            XCTAssertEqual(report.sampleCount, 2)
            XCTAssertEqual(report.averageMgDl, 150, accuracy: 0.000001)
        }
    }

    @MainActor
    func testStatisticsManualPeriodChangeIncludesReadingsAfterOpeningCutoff() async throws {
        try await withStatisticsStore { core in
            let current = Date()
            let openingEnd = current.addingTimeInterval(-600)
            _ = self.addStatisticsReading(core, at: current.addingTimeInterval(-900), value: 120)
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = StatisticsManager(coreDataManager: core)
            let model = StatisticsViewModel(statisticsManager: manager, now: { openingEnd })
            await self.completeStatisticsLoad(model)
            XCTAssertEqual(model.analytics?.periodEnd, openingEnd)
            XCTAssertEqual(model.analytics?.sampleCount, 1)

            let newlyReceivedAt = current.addingTimeInterval(-60)
            _ = self.addStatisticsReading(core, at: newlyReceivedAt, value: 180)
            XCTAssertTrue(core.saveChangesSynchronously())
            let finished = self.expectation(description: "Manual period selection uses current data")
            let subscription = model.$isLoading.dropFirst().first { !$0 }.sink { _ in finished.fulfill() }
            model.selectedPeriod = .thirty
            await self.fulfillment(of: [finished], timeout: 10)
            subscription.cancel()
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.selectedPeriod, .thirty)
            XCTAssertGreaterThan(try XCTUnwrap(model.analytics?.periodEnd), newlyReceivedAt)
            XCTAssertEqual(model.analytics?.sampleCount, 2)
            XCTAssertEqual(model.analytics?.averageMgDl, 150)
        }
    }

    @MainActor
    func testStatisticsRapidPeriodChangesAndReopeningDiscardOldCompletion() async throws {
        try await withStatisticsStore { core in
            let firstEnd = Date(timeIntervalSince1970: 1_800_000_000)
            _ = self.addStatisticsReading(core, at: firstEnd.addingTimeInterval(-300), value: 120)
            // This row is outside the first request but inside the latest one. A stale result
            // must neither publish the earlier cutoff nor hide this newly eligible reading.
            _ = self.addStatisticsReading(core, at: firstEnd.addingTimeInterval(90), value: 180)
            XCTAssertTrue(core.saveChangesSynchronously())
            let firstFetch = self.expectation(description: "First real SQLite fetch started")
            let releaseFirst = DispatchSemaphore(value: 0)
            defer { releaseFirst.signal() }
            let fetches = StatisticsFetchProbe(first: {
                firstFetch.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 10)
            })
            let manager = StatisticsManager(coreDataManager: core)
            manager.glucoseFetchObserver = { fetches.record(start: $0, end: $1) }
            var now = firstEnd
            let model = StatisticsViewModel(statisticsManager: manager, now: { now })
            var publications = [GlucoseReportAnalytics]()
            let subscription = model.$analytics.compactMap { $0 }.sink { publications.append($0) }
            defer { subscription.cancel() }
            model.load()
            await self.fulfillment(of: [firstFetch], timeout: 5)
            model.selectedPeriod = .thirty
            model.selectedPeriod = .seven
            now = firstEnd.addingTimeInterval(60)
            model.load()
            now = firstEnd.addingTimeInterval(120)
            let finished = self.expectation(description: "Only newest load completes")
            let lowSoonFinished = self.expectation(description: "Newest low-warning statistics complete")
            let loading = model.$isLoading.dropFirst().first { !$0 }.sink { _ in finished.fulfill() }
            let lowSoon = model.$lowSoonStatistics.dropFirst().compactMap { $0 }.first()
                .sink { _ in lowSoonFinished.fulfill() }
            model.load()
            releaseFirst.signal()
            await self.fulfillment(of: [finished, lowSoonFinished], timeout: 10)
            loading.cancel()
            lowSoon.cancel()
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.selectedPeriod, .seven)
            XCTAssertEqual(publications.count, 1)
            XCTAssertEqual(model.analytics?.periodEnd, now)
            XCTAssertEqual(model.analytics?.sampleCount, 2)
            XCTAssertEqual(model.analytics?.averageMgDl, 150)
        }
    }

    @MainActor
    private func completeStatisticsLoad(_ model: StatisticsViewModel,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        let finished = expectation(description: "Statistics load completed")
        let lowSoonFinished = expectation(description: "Low-warning statistics completed")
        let subscription = model.$isLoading.dropFirst().first { !$0 }.sink { _ in finished.fulfill() }
        let lowSoonSubscription = model.$lowSoonStatistics.dropFirst().compactMap { $0 }.first()
            .sink { _ in lowSoonFinished.fulfill() }
        model.load()
        await fulfillment(of: [finished, lowSoonFinished], timeout: 10)
        subscription.cancel()
        lowSoonSubscription.cancel()
        XCTAssertFalse(model.isLoading, file: file, line: line)
    }

    @MainActor
    private func withStatisticsStore(_ body: (CoreDataManager) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: directory.appendingPathComponent("Statistics.sqlite"))
        defer {
            try? core.disconnectPersistentStoresForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(core)
    }

    @MainActor
    @discardableResult
    private func addStatisticsReading(_ core: CoreDataManager, at date: Date, value: Double) -> BgReading {
        let reading = BgReading(timeStamp: date, sensor: nil, calibration: nil,
            rawData: value, deviceName: "Statistics regression",
            nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = value
        return reading
    }

    private func statisticsConfiguration(period: GlucoseReportPeriod) -> GlucoseReportConfiguration {
        GlucoseReportConfiguration(patientName: "Statistics regression", patientID: "Synthetic data",
            period: period, aidPeriod: .notIncluded, paperSize: .a4, language: .english, usesIFCC: false)
    }

    private final class StatisticsFetchProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storedWindows: [DateInterval] = []
        private let first: (() -> Void)?
        init(first: (() -> Void)? = nil) { self.first = first }
        var windows: [DateInterval] {
            lock.lock()
            defer { lock.unlock() }
            return storedWindows
        }
        func record(start: Date, end: Date) {
            lock.lock()
            storedWindows.append(DateInterval(start: start, end: end))
            let isFirst = storedWindows.count == 1
            lock.unlock()
            if isFirst { first?() }
        }
    }

}
