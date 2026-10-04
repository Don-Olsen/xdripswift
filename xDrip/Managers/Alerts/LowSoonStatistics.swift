//
//  LowSoonStatistics.swift
//  xdrip
//
//  Descriptive, local-only evaluation of the "Low soon" alert. A request to
//  schedule a notification is never evidence that the person received it.
//

import Foundation

struct LowSoonStatisticsGlucose: Sendable {
    let date: Date
    let mgdl: Double
    let sensorID: String?
}

struct LowSoonStatisticsEvaluation: Sendable {
    enum Status: Sendable {
        case unavailable
        case noWarning
        case warningRequested
        case warningSchedulingFailed
        case suppressed
    }

    let referenceDate: Date?
    let computedAt: Date
    let status: Status

    static func fromJournal(_ record: LowSoonEvaluationRecord) -> Self {
        let mapped: Status
        switch record.status {
        case .unavailable: mapped = .unavailable
        case .noWarning: mapped = .noWarning
        case .warningRequested: mapped = .warningRequested
        case .warningSchedulingFailed: mapped = .warningSchedulingFailed
        case .suppressed:
            // Disabled or snoozed periods have no valid warning opportunity.
            // A cooldown after a requested warning is still observed coverage.
            mapped = record.detail == "disabled" || record.detail == "snoozed"
                ? .unavailable : .suppressed
        }
        return .init(referenceDate: record.referenceDate,
                     computedAt: record.computedAt, status: mapped)
    }
}

struct LowSoonStatisticsSummary: Sendable {
    let periodStart: Date
    let periodEnd: Date
    let lowEpisodes: Int
    let evaluableEpisodes: Int
    let episodesWithPlannedWarning: Int
    let meanPlannedLeadMinutes: Double?
    let evaluableDays: Int
    let plannedWarningsWithoutRecordedLow: Int
    let thoseWithRecordedCarbs: Int
    let thoseReachingBelow4Point4: Int
    let unevaluableWarnings: Int

    var plannedWarningFraction: Double? {
        guard evaluableEpisodes > 0 else { return nil }
        return Double(episodesWithPlannedWarning) / Double(evaluableEpisodes)
    }

    var plannedWarningsWithoutLowPerEvaluableDay: Double? {
        guard evaluableDays > 0 else { return nil }
        return Double(plannedWarningsWithoutRecordedLow) / Double(evaluableDays)
    }
}

enum LowSoonStatisticsCalculator {
    // Both the 1-minute and configured 5-minute streams can be continuous.
    // A longer gap makes that interval unknown instead of normal glucose.
    static let maximumContinuousGap: TimeInterval = 5.5 * 60
    static let minimumLowDuration: TimeInterval = 15 * 60
    static let warningWindow: TimeInterval = 30 * 60
    static let lowThresholdMgdl = 3.9 / ConstantsBloodGlucose.mgDlToMmoll
    static let nearLowThresholdMgdl = 4.4 / ConstantsBloodGlucose.mgDlToMmoll

    static func calculate(glucose rawGlucose: [LowSoonStatisticsGlucose],
                          evaluations rawEvaluations: [LowSoonStatisticsEvaluation],
                          confirmedCarbDates: [Date], period: DateInterval,
                          calendar: Calendar = .current) -> LowSoonStatisticsSummary {
        let normalizedGlucose = normalized(rawGlucose)
        let glucose = normalizedGlucose.samples
        let conflictDates = normalizedGlucose.conflictDates
        let evaluations = rawEvaluations.sorted {
            let left = $0.referenceDate ?? $0.computedAt
            let right = $1.referenceDate ?? $1.computedAt
            return left == right ? $0.computedAt < $1.computedAt : left < right
        }
        // The policy permits no second legitimate request inside 30 minutes.
        // A replayed journal line or duplicate callback must not inflate counts.
        let warningTimes = evaluations.filter { $0.status == .warningRequested }
            .map(\.computedAt).sorted().reduce(into: [Date]()) { unique, date in
                if unique.last.map({ date.timeIntervalSince($0) >= 60 }) ?? true {
                    unique.append(date)
                }
            }
        let carbDates = confirmedCarbDates.sorted()

        let episodes = lowEpisodes(in: glucose, conflictDates: conflictDates).filter {
            $0.start >= period.start && $0.start < period.end
        }
        var evaluableEpisodes = 0
        var episodesWithPlannedWarning = 0
        var leadMinutes: [Double] = []
        for episode in episodes {
            let windowStart = episode.start.addingTimeInterval(-warningWindow)
            let priorWarnings = warningTimes.filter { $0 >= windowStart && $0 < episode.start }
            // A recorded request proves an alert was planned, even if another
            // evaluation in the lookback was unavailable. With no request,
            // require complete evaluation coverage before calling it a miss.
            guard !priorWarnings.isEmpty ||
                evaluationCoverage(evaluations, from: windowStart, to: episode.start)
            else { continue }
            evaluableEpisodes += 1
            if let latest = priorWarnings.last {
                episodesWithPlannedWarning += 1
                leadMinutes.append(episode.start.timeIntervalSince(latest) / 60)
            }
        }

        var evaluableDays = 0
        var plannedWithoutLow = 0
        var withCarbs = 0
        var below4Point4 = 0
        var unevaluableWarnings = 0
        var dayStart = calendar.startOfDay(for: period.start)
        while dayStart < period.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let dayWarnings = warningTimes.filter { $0 >= dayStart && $0 < nextDay && $0 >= period.start }
            let fullDay = dayStart >= period.start && nextDay <= period.end &&
                glucoseCoverage(glucose, conflictDates: conflictDates,
                    from: dayStart, to: nextDay) &&
                evaluationCoverage(evaluations, from: dayStart, to: nextDay)
            if fullDay { evaluableDays += 1 }
            for warning in dayWarnings {
                let end = warning.addingTimeInterval(warningWindow)
                guard fullDay, end <= period.end,
                      glucoseCoverage(glucose, conflictDates: conflictDates,
                          from: warning, to: end) else {
                    unevaluableWarnings += 1
                    continue
                }
                let following = glucose.filter { $0.date >= warning && $0.date <= end }
                guard !following.contains(where: { $0.mgdl < lowThresholdMgdl }) else { continue }
                plannedWithoutLow += 1
                if carbDates.contains(where: { $0 >= warning && $0 <= end }) { withCarbs += 1 }
                if following.contains(where: { $0.mgdl < nearLowThresholdMgdl }) { below4Point4 += 1 }
            }
            dayStart = nextDay
        }

        return LowSoonStatisticsSummary(periodStart: period.start, periodEnd: period.end,
            lowEpisodes: episodes.count, evaluableEpisodes: evaluableEpisodes,
            episodesWithPlannedWarning: episodesWithPlannedWarning,
            meanPlannedLeadMinutes: leadMinutes.isEmpty ? nil : leadMinutes.reduce(0, +) / Double(leadMinutes.count),
            evaluableDays: evaluableDays,
            plannedWarningsWithoutRecordedLow: plannedWithoutLow,
            thoseWithRecordedCarbs: withCarbs,
            thoseReachingBelow4Point4: below4Point4,
            unevaluableWarnings: unevaluableWarnings)
    }

    private struct LowEpisode {
        let start: Date
        let end: Date
    }

    private static func lowEpisodes(in samples: [LowSoonStatisticsGlucose],
                                    conflictDates: [Date]) -> [LowEpisode] {
        var episodes: [LowEpisode] = []
        var start: Date?
        var lastLow: LowSoonStatisticsGlucose?
        func finish() {
            if let start, let lastLow,
               lastLow.date.timeIntervalSince(start) >= minimumLowDuration {
                episodes.append(LowEpisode(start: start, end: lastLow.date))
            }
            start = nil
            lastLow = nil
        }
        for sample in samples {
            if let lastLow,
               (!continuous(lastLow, sample) || conflictDates.contains {
                   $0 > lastLow.date && $0 <= sample.date
               }) { finish() }
            if sample.mgdl < lowThresholdMgdl {
                if start == nil { start = sample.date }
                lastLow = sample
            } else {
                finish()
            }
        }
        finish()
        return episodes
    }

    private static func normalized(_ samples: [LowSoonStatisticsGlucose])
        -> (samples: [LowSoonStatisticsGlucose], conflictDates: [Date]) {
        let sorted = samples.sorted { $0.date < $1.date }
        var result: [LowSoonStatisticsGlucose] = []
        var conflicts: [Date] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var next = index + 1
            while next < sorted.count && sorted[next].date == first.date { next += 1 }
            let duplicates = sorted[index..<next]
            if duplicates.allSatisfy({ $0.mgdl.isFinite && (20...600).contains($0.mgdl) &&
                $0.mgdl == first.mgdl && $0.sensorID == first.sensorID }) {
                result.append(first)
            } else {
                conflicts.append(first.date)
            }
            // Conflicting same-time readings become a gap. Never choose a
            // convenient value to inflate apparent coverage or miss a low.
            index = next
        }
        return (result, conflicts)
    }

    private static func continuous(_ older: LowSoonStatisticsGlucose,
                                   _ newer: LowSoonStatisticsGlucose) -> Bool {
        newer.date.timeIntervalSince(older.date) <= maximumContinuousGap &&
            older.sensorID == newer.sensorID
    }

    private static func glucoseCoverage(_ samples: [LowSoonStatisticsGlucose],
                                        conflictDates: [Date],
                                        from start: Date, to end: Date) -> Bool {
        guard !conflictDates.contains(where: { $0 >= start && $0 <= end }) else { return false }
        let included = samples.filter { $0.date >= start && $0.date <= end }
        guard let first = included.first, let last = included.last,
              first.date.timeIntervalSince(start) <= maximumContinuousGap,
              end.timeIntervalSince(last.date) <= maximumContinuousGap else { return false }
        return zip(included, included.dropFirst()).allSatisfy { continuous($0.0, $0.1) }
    }

    private static func evaluationCoverage(_ evaluations: [LowSoonStatisticsEvaluation],
                                           from start: Date, to end: Date) -> Bool {
        guard !evaluations.contains(where: {
            $0.status == .unavailable &&
                ($0.referenceDate ?? $0.computedAt) >= start &&
                ($0.referenceDate ?? $0.computedAt) <= end
        }) else { return false }
        let covered = evaluations.compactMap { item -> Date? in
            guard item.status != .unavailable, let reference = item.referenceDate,
                  reference >= start, reference <= end else { return nil }
            return reference
        }.sorted()
        guard let first = covered.first, let last = covered.last,
              first.timeIntervalSince(start) <= maximumContinuousGap,
              end.timeIntervalSince(last) <= maximumContinuousGap else { return false }
        return zip(covered, covered.dropFirst()).allSatisfy {
            $1.timeIntervalSince($0) <= maximumContinuousGap
        }
    }
}
