//
//  StatisticsViewModel.swift
//  xdrip
//
//  Created by Paul Plant on 21/7/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation

/// Loads report analytics and period availability for the Statistics screen.
@MainActor
final class StatisticsViewModel: ObservableObject {
    @Published var selectedPeriod: GlucoseReportPeriod = .ninety {
        didSet {
            guard oldValue != selectedPeriod, !isLoadingAvailability else { return }
            loadAnalytics()
        }
    }
    @Published private(set) var analytics: GlucoseReportAnalytics?
    @Published private(set) var availablePeriods: [GlucoseReportPeriod: Bool] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var lowSoonStatistics: LowSoonStatisticsSummary?

    private let statisticsManager: StatisticsManager
    private let now: () -> Date
    private var availabilityTask: Task<Void, Never>?
    private var isLoadingAvailability = false
    private var analyticsTask: Task<Void, Never>?
    private var lowSoonTask: Task<Void, Never>?

    init(statisticsManager: StatisticsManager, now: @escaping () -> Date = Date.init) {
        self.statisticsManager = statisticsManager
        self.now = now
    }

    /// Loads available periods before requesting analytics for the selected period.
    func load() {
        availabilityTask?.cancel()
        analyticsTask?.cancel()
        lowSoonTask?.cancel()
        let referenceDate = now()
        isLoading = true
        isLoadingAvailability = true
        availabilityTask = Task {
            guard !Task.isCancelled else { return }
            let availability = await statisticsManager.availableReportPeriods(referenceDate: referenceDate)
            guard !Task.isCancelled else { return }
            availablePeriods = availability
            if availability[selectedPeriod] != true {
                selectedPeriod = defaultPeriod(from: availability)
            }
            isLoadingAvailability = false
            loadAnalytics(referenceDate: referenceDate)
            // Reuse the wide glucose window and its exact cutoff for both summaries.
            lowSoonTask = Task {
                guard !Task.isCancelled else { return }
                let summary = await statisticsManager.lowSoonStatistics(now: referenceDate)
                guard !Task.isCancelled else { return }
                lowSoonStatistics = summary
            }
        }
    }

    func isPeriodAvailable(_ period: GlucoseReportPeriod) -> Bool {
        availablePeriods[period] ?? false
    }

    var selectablePeriods: [GlucoseReportPeriod] {
        GlucoseReportPeriod.allCases.filter { isPeriodAvailable($0) }
    }

    private func loadAnalytics(referenceDate: Date? = nil) {
        analyticsTask?.cancel()
        let requestedPeriod = selectedPeriod
        let configuration = GlucoseReportConfiguration(
            patientName: UserDefaults.standard.reportPatientName,
            patientID: UserDefaults.standard.reportPatientID,
            period: selectedPeriod,
            aidPeriod: .notIncluded,
            paperSize: UserDefaults.standard.reportPaperSize,
            language: UserDefaults.standard.reportLanguage
        )

        analyticsTask = Task {
            guard !Task.isCancelled else { return }
            isLoading = true
            let requestedAnalytics = await statisticsManager.reportAnalytics(for: configuration,
                                                                              referenceDate: referenceDate)
            guard !Task.isCancelled, selectedPeriod == requestedPeriod else { return }
            analytics = requestedAnalytics
            isLoading = false
        }
    }

    private func defaultPeriod(from availability: [GlucoseReportPeriod: Bool]) -> GlucoseReportPeriod {
        [.ninety, .sixty, .thirty, .seven, .oneEighty, .oneYear].first { availability[$0] == true } ?? .seven
    }
}
