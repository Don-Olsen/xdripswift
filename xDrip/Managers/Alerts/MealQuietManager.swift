import Combine
import CoreData
import Foundation
import UIKit
import UserNotifications

/// Separate from snooze: it must never inherit Watch's shared high/urgent-high snooze group.
struct MealQuietRecord: Codable, Equatable {
    enum Decision: String, Codable { case pending, rejected, active, ended }
    let mealID: String
    let bolusID: String
    let eatingAt: Date
    let until: Date
    var decision: Decision
    var reason: String
    var sourceSignature: String? = nil
    var sensorID: String? = nil
    var endedAt: Date? = nil

    var period: MealQuietPeriod { .init(mealID: mealID, startedAt: eatingAt, until: until) }
}

struct MealQuietDocument: Codable, Equatable {
    var schema = 1
    var revision = 0
    var enabled = false
    var durationMinutes: Int?
    var records: [String: MealQuietRecord] = [:]

    var active: MealQuietRecord? { records.values.first { $0.decision == .active } }
    var hasPending: Bool { records.values.contains { $0.decision == .pending } }
}

struct MealQuietRules: Equatable {
    let low: Double
    let high: Double
    let urgentHigh: Double
    var usesMgDl = true

    var isValid: Bool {
        [low, high, urgentHigh].allSatisfy { $0.isFinite && (20...600).contains($0) } &&
            low < high && high < urgentHigh
    }

    func permitsCurrent(_ glucose: Double, starting: Bool) -> Bool {
        isValid && glucose.isFinite && glucose >= LowSoonAlertPolicy.currentMinimumMgdl &&
            glucose.bgValueRounded(mgDl: usesMgDl) > low.bgValueRounded(mgDl: usesMgDl) &&
            glucose.bgValueRounded(mgDl: usesMgDl) < urgentHigh.bgValueRounded(mgDl: usesMgDl) &&
            (!starting || belowHigh(glucose))
    }

    func belowHigh(_ glucose: Double) -> Bool {
        glucose.bgValueRounded(mgDl: usesMgDl) < high.bgValueRounded(mgDl: usesMgDl)
    }
}

/// One small atomic document. A failed write removes permission to suppress; it never changes
/// Core Data, the treatment journal, a dose, or an alarm's existing snooze/repeat state.
@MainActor final class MealQuietManager: ObservableObject {
    static let shared = MealQuietManager()
    static let changed = Notification.Name("xdrip.mealQuiet.changed")
    static let validDurationMinutes = [15, 30, 45, 60]

    /// Narrow dependencies for exercising the production asynchronous lifecycle without
    /// changing global therapy settings or delivering real notifications in tests.
    struct InputState {
        let token: String?
        let treatmentRevision: Int
        let hasUncommitted: Bool
    }

    struct InputOverrides {
        var pairIsValid: ((MealQuietRecord) -> Bool)?
        var latestGlucose: (() -> GlucoseForecastSample?)?
        var currentRules: ((Date) -> MealQuietRules?)?
        var inputState: (() -> InputState)?
        var contextSignature: (() -> String)?
        var forecast: ((CoreDataManager, Date) async -> GlucoseForecastSafetyOutcome)?
    }

    @Published private(set) var revision: Int
    @Published private(set) var isEnabled: Bool
    @Published private(set) var durationMinutes: Int?

    private(set) var document: MealQuietDocument
    private var storageAvailable = true
    private let loadData: () throws -> Data?
    private let saveData: (Data) throws -> Void
    private let inputOverrides: InputOverrides
    private let clock: () -> Date
    private let clearHighSoon: () -> Void
    private let recoveryDefaults: UserDefaults?
    private static let recoveryKey = "mealQuietUnfinishedWriteV1"
    private var coreDataManager: CoreDataManager?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var safety: (outcome: GlucoseForecastSafetyOutcome, token: String)?
    private var checkedPairRevision: Int?
    private var refreshing = false

    init(directory: URL? = nil, load: (() throws -> Data?)? = nil,
         save: ((Data) throws -> Void)? = nil,
         inputOverrides: InputOverrides = .init(), clock: @escaping () -> Date = Date.init,
         recoveryDefaults: UserDefaults? = nil,
         clearHighSoon: @escaping () -> Void = { AlertManager.clearHighSoonNotifications() }) {
        self.recoveryDefaults = recoveryDefaults ?? (directory == nil && load == nil && save == nil ? .standard : nil)
        self.inputOverrides = inputOverrides
        self.clock = clock
        self.clearHighSoon = clearHighSoon
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("PenDose/MealQuiet", isDirectory: true)
        let url = folder.appendingPathComponent("state.json")
        loadData = load ?? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
        saveData = save ?? { data in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: folder.path)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
        }
        var restored = MealQuietDocument()
        do {
            if let data = try loadData() {
                restored = try JSONDecoder().decode(MealQuietDocument.self, from: data)
                guard restored.schema == 1, restored.revision >= 0,
                      restored.durationMinutes.map(Self.validDurationMinutes.contains) ?? true,
                      restored.records.values.filter({ $0.decision == .active }).count <= 1,
                      restored.records.allSatisfy({ key, record in
                          key == record.mealID && !key.isEmpty && !record.bolusID.isEmpty &&
                          record.eatingAt.timeIntervalSince1970.isFinite &&
                          record.until.timeIntervalSince1970.isFinite &&
                          (record.endedAt.map { $0.timeIntervalSince1970.isFinite && $0 <= record.until } ?? true) &&
                          (0...3600).contains(record.until.timeIntervalSince(record.eatingAt)) &&
                          ((record.decision != .active && record.decision != .pending) ||
                           Self.validDurationMinutes.contains(where: {
                               abs(record.until.timeIntervalSince(record.eatingAt) - Double($0 * 60)) < 0.001
                           }))
                      }) else { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch {
            storageAvailable = false
            restored = MealQuietDocument()
        }
        document = restored
        revision = restored.revision
        isEnabled = restored.enabled && storageAvailable
        durationMinutes = restored.durationMinutes
        // A separate small fence prevents an old active file from surviving an interrupted
        // Stop/write. Recover conservatively to OFF, preserving per-meal terminal identities.
        if self.recoveryDefaults?.bool(forKey: Self.recoveryKey) == true {
            var next = restored
            next.enabled = false
            terminateRecords(&next, mealID: nil, reason: "Afbrudt lagring – almindelige alarmer er aktive")
            _ = persist(next)
        }
        // An interrupted one-shot decision must not later use different glucose to start.
        else if restored.hasPending {
            var next = restored
            for id in next.records.keys where next.records[id]?.decision == .pending {
                guard let record = next.records[id] else { continue }
                next.records[id]?.decision = .rejected
                next.records[id]?.reason = "Afbrudt startvurdering"
                next.records[id]?.endedAt = min(clock(), record.until)
            }
            _ = persist(next)
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(coreDataManager: CoreDataManager) {
        guard self.coreDataManager !== coreDataManager else { return }
        self.coreDataManager = coreDataManager
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [TherapyMetricsManager.changed, UserDefaults.didChangeNotification,
                     NSNotification.Name.NSManagedObjectContextDidSave,
                     UIApplication.didBecomeActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.significantTimeChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshMeasuredBasis(at: self.clock())
                }
            }
        }
        refreshMeasuredBasis(at: clock())
        // Restoring a durable period does not restore stale safety permission. Revalidate once.
        if document.active != nil { refreshRestoredSafety() }
    }

    var watchState: MealQuietSyncState {
        .init(revision: revision, period: storageAvailable && isEnabled ? document.active?.period : nil)
    }

    func setEnabled(_ enabled: Bool) {
        var next = document
        next.enabled = enabled
        if !enabled { terminateRecords(&next, mealID: nil, reason: "Slået fra") }
        if persist(next) { refreshMeasuredBasis(at: clock()) }
    }

    func setDurationMinutes(_ minutes: Int) {
        guard Self.validDurationMinutes.contains(minutes) else { return }
        var next = document
        next.durationMinutes = minutes
        _ = persist(next) // The active record's absolute expiry is deliberately untouched.
    }

    func activePeriod(at now: Date = .now) -> MealQuietPeriod? {
        guard storageAvailable, isEnabled, let active = document.active,
              active.period.isActive(at: now) else { return nil }
        return active.period
    }

    func end(mealID: String? = nil, reason: String, at now: Date = .now) {
        guard document.records.values.contains(where: {
            (mealID == nil || $0.mealID == mealID) && ($0.decision == .active || $0.decision == .pending)
        }) else { return }
        var next = document
        terminateRecords(&next, mealID: mealID, reason: reason, at: now)
        generation &+= 1
        startTask?.cancel()
        safety = nil
        _ = persist(next)
        activity(reason)
    }

    private func terminateRecords(_ state: inout MealQuietDocument, mealID: String?, reason: String, at now: Date? = nil) {
        for id in state.records.keys where mealID == nil || id == mealID {
            guard let record = state.records[id], record.decision == .active || record.decision == .pending else { continue }
            state.records[id]?.decision = record.decision == .pending ? .rejected : .ended
            state.records[id]?.reason = reason
            state.records[id]?.endedAt = min(now ?? clock(), record.until)
        }
    }

    @discardableResult private func persist(_ proposed: MealQuietDocument) -> Bool {
        var next = proposed
        next.revision = max(document.revision + 1, Int(Date().timeIntervalSince1970 * 1000))
        do {
            recoveryDefaults?.set(true, forKey: Self.recoveryKey)
            if let recoveryDefaults, !recoveryDefaults.synchronize() {
                throw CocoaError(.fileWriteUnknown)
            }
            try saveData(JSONEncoder().encode(next))
            recoveryDefaults?.set(false, forKey: Self.recoveryKey)
            _ = recoveryDefaults?.synchronize()
            document = next
            storageAvailable = true
            isEnabled = next.enabled
            durationMinutes = next.durationMinutes
            revision = next.revision
            NotificationCenter.default.post(name: Self.changed, object: self)
            return true
        } catch {
            // An unsuccessful pending/active write is terminal in this process as well.
            // A later settings save must not revive it or leave every new meal blocked.
            terminateRecords(&next, mealID: nil, reason: "Lagring af måltidsro mislykkedes")
            document = next
            storageAvailable = false
            safety = nil
            revision = next.revision
            NotificationCenter.default.post(name: Self.changed, object: self)
            activity("Kunne ikke gemme måltidsro – almindelige alarmer er aktive")
            return false
        }
    }

    private func activity(_ reason: String) {
        TroubleshootingLogStore.shared.record(.standard(.alert(kindRawValue: AlertKind.high.rawValue,
                                                               activity: .mealQuiet(reason: reason))))
    }

    /// Only explicit durable registration/confirmation calls this. A retry cannot create a new
    /// start decision; disabled mode has no side effects in ordinary treatment registration.
    func considerCommittedMeal(coreDataManager: CoreDataManager, mealID: String, bolusID: String,
                               eatingAt: Date, eventAt: Date, allowsStart: Bool = true) {
        guard isEnabled, document.records[mealID] == nil else { return }
        self.coreDataManager = coreDataManager
        let now = clock()
        refreshMeasuredBasis(at: now)
        let until = eatingAt.addingTimeInterval(Double(durationMinutes ?? 0) * 60)
        var record = MealQuietRecord(mealID: mealID, bolusID: bolusID, eatingAt: eatingAt,
                                    until: until, decision: .pending, reason: "Vurderer registreret måltid")
        let rejection: String?
        if !allowsStart { rejection = "Registreringen havde ikke et aktuelt startgrundlag" }
        else if !storageAvailable { rejection = "Måltidsroens lagring er utilgængelig" }
        else if durationMinutes == nil { rejection = "Varighed er ikke valgt" }
        else if document.active != nil || document.hasPending { rejection = "En periode er allerede startet eller under vurdering" }
        // A treatment commit/observer can end the old period before this callback. The
        // registration's pre-save event time must not then start a replacement period.
        // Expiry is capped at the original until so delayed cleanup does not block a new meal.
        else if document.records.values.contains(where: { $0.endedAt.map { eventAt <= $0 } ?? false }) {
            rejection = "Registreringen begyndte før den forrige periode var afsluttet"
        }
        else if !eventAt.timeIntervalSince1970.isFinite || !(0...30).contains(now.timeIntervalSince(eventAt)) ||
                    !record.period.isActive(at: now) || eatingAt > eventAt { rejection = "Måltidets starttid er ikke aktuel" }
        else if !pairIsValid(record) { rejection = "Gemte mad- og insulinregistreringer kunne ikke bekræftes" }
        else { rejection = nil }
        if let rejection { record.decision = .rejected; record.reason = rejection }
        var next = document
        next.records[mealID] = record
        guard persist(next) else { return }
        if let rejection { activity(rejection); return }
        guard let token = inputRevisionToken(), let measured = latestGlucose(),
              let rules = currentRules(at: now), rules.permitsCurrent(measured.glucoseMgdl, starting: true),
              fresh(measured, at: now) else {
            end(mealID: mealID, reason: "Måling, alarmregler eller behandlingsgrundlag er ikke egnet til start", at: now)
            return
        }
        generation &+= 1
        let attempt = generation
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await forecast(coreDataManager: coreDataManager, at: now)
            guard !Task.isCancelled, generation == attempt,
                  document.records[mealID]?.decision == .pending else { return }
            let finishedAt = clock()
            guard token == inputRevisionToken(), latestGlucose() == measured,
                  pairIsValid(record), let rules = currentRules(at: finishedAt),
                  rules.permitsCurrent(measured.glucoseMgdl, starting: true),
                  record.period.isActive(at: finishedAt),
                  let risk = validatedRisk(outcome, at: finishedAt), !risk else {
                end(mealID: mealID, reason: "Start afvist: lavrisiko eller ufuldstændigt/ændret grundlag", at: finishedAt)
                return
            }
            var approved = document
            approved.records[mealID]?.decision = .active
            approved.records[mealID]?.reason = "Startet efter gemt mad og insulin"
            approved.records[mealID]?.sourceSignature = contextSignature()
            approved.records[mealID]?.sensorID = measured.sensorID
            safety = (outcome, token)
            checkedPairRevision = inputState().treatmentRevision
            if persist(approved) {
                clearHighSoon()
                activity("Startet efter gemt mad og insulin")
            }
        }
    }

    /// Snapshot identity excludes unrelated UI settings; no managed object crosses a queue.
    func inputRevisionToken() -> String? { inputState().token }

    private func contextSignature() -> String {
        inputOverrides.contextSignature?() ??
            GlucoseForecastDataAdapter.presentationInputSignature(horizonMinutes: 120)
    }

    private func inputState() -> InputState {
        if let override = inputOverrides.inputState { return override() }
        let therapy = TherapyMetricsManager.shared
        let importer = HealthKitTherapyImportManager.shared
        let defaults = UserDefaults.standard
        guard !therapy.hasUncommittedForecastInputChanges,
              !importer.localInputIsIncomplete(.insulin), !importer.localInputIsIncomplete(.carbohydrates),
              TherapyMetricsManager.doseSourceIsReady(defaults.dataFlowPolicy,
                  cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults) else {
            return .init(token: nil, treatmentRevision: therapy.treatmentChangeRevision,
                         hasUncommitted: therapy.hasUncommittedForecastInputChanges)
        }
        return .init(token: "\(therapy.treatmentChangeRevision)|\(therapy.forecastInputChangeRevision)|" +
            contextSignature(), treatmentRevision: therapy.treatmentChangeRevision, hasUncommitted: false)
    }

    /// Called from the existing saved-reading safety pipeline, before alert enable/snooze checks.
    /// A stale result cannot stop a newer period or regain permission to suppress.
    func acceptSafetyOutcome(_ outcome: GlucoseForecastSafetyOutcome, token: String?, at now: Date = .now) {
        guard document.active != nil, let token, token == inputRevisionToken() else { return }
        guard outcome.result.reason == nil else {
            end(reason: "Prognosegrundlaget kunne ikke bekræftes", at: now); return
        }
        guard let latest = latestGlucose(), outcome.result.referenceDate == latest.date,
              outcome.referenceGlucoseMgdl == latest.glucoseMgdl,
              outcome.result.referenceSensorID == latest.sensorID else { return }
        refreshMeasuredBasis(at: now)
        guard document.active != nil else { return }
        guard let risk = validatedRisk(outcome, at: now) else {
            end(reason: "Prognosegrundlaget kunne ikke bekræftes", at: now); return
        }
        if risk { end(reason: "Risiko for lavt blodsukker", at: now); return }
        safety = (outcome, token)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// No polling. A still-fresh, previously validated forecast can bridge a newer reading
    /// while the existing worker finishes. Changed treatments/settings/sensor or a revised
    /// anchor never reuse it. Measured low/urgent high stops the period synchronously.
    func refreshMeasuredBasis(at now: Date = .now) {
        guard !refreshing, let active = document.active else { return }
        refreshing = true
        defer { refreshing = false }
        guard active.period.isActive(at: now), isEnabled, storageAvailable else {
            end(reason: "Perioden er afsluttet", at: now); return
        }
        guard let latest = latestGlucose(), fresh(latest, at: now),
              let rules = currentRules(at: now), rules.permitsCurrent(latest.glucoseMgdl, starting: false) else {
            end(reason: "Måling eller alarmregler kræver almindelig alarmadfærd", at: now); return
        }
        guard active.sourceSignature == contextSignature(), active.sensorID == latest.sensorID else {
            end(reason: "Datakilde eller behandlingsindstillinger er ændret", at: now); return
        }
        let state = inputState()
        // Unknown treatment state cannot silently resume the same period later. This is
        // independent of the treatment transaction, which is neither delayed nor cancelled.
        if state.hasUncommitted {
            end(reason: "Behandlingsgrundlaget er under ændring", at: now); return
        }
        guard let token = inputRevisionToken() else {
            end(reason: "Behandlingsgrundlaget er ikke komplet", at: now); return
        }
        guard pairLinkIsValid(active) else {
            end(reason: "Måltidets tilknyttede insulin kunne ikke bekræftes", at: now); return
        }
        if checkedPairRevision != state.treatmentRevision {
            guard pairIsValid(active) else {
                end(reason: "Måltidet eller den tilknyttede insulin er ændret eller slettet", at: now); return
            }
            checkedPairRevision = state.treatmentRevision
        }
        if let safety, safety.token != token || !anchorMatches(safety.outcome, latest: latest) {
            end(reason: "Beregningsgrundlaget er ændret", at: now); return
        }
        if let safety {
            guard let risk = validatedRisk(safety.outcome, at: now) else {
                end(reason: "Prognosegrundlaget er ikke længere aktuelt", at: now); return
            }
            if risk { end(reason: "Risiko for lavt blodsukker", at: now) }
        }
    }

    func shouldSuppress(_ kind: AlertKind, at now: Date = .now) -> Bool {
        guard kind == .high || kind == .fastrise else { return false }
        refreshMeasuredBasis(at: now)
        guard activePeriod(at: now) != nil, let safety, safety.token == inputRevisionToken(),
              validatedRisk(safety.outcome, at: now) == false,
              let current = latestGlucose(), let rules = currentRules(at: now) else { return false }
        return kind == .high || rules.belowHigh(current.glucoseMgdl)
    }

    func shouldSuppressHighSoon(at now: Date = .now) -> Bool { shouldSuppress(.high, at: now) }

    private func anchorMatches(_ outcome: GlucoseForecastSafetyOutcome,
                               latest: GlucoseForecastSample) -> Bool {
        guard let reference = outcome.result.referenceDate,
              latest.date >= reference, latest.sensorID == outcome.result.referenceSensorID else { return false }
        return latest.date > reference || latest.glucoseMgdl == outcome.referenceGlucoseMgdl
    }

    private func validatedRisk(_ outcome: GlucoseForecastSafetyOutcome, at now: Date) -> Bool? {
        guard let latest = latestGlucose(), fresh(latest, at: now), anchorMatches(outcome, latest: latest),
              let reference = outcome.result.referenceDate, let glucose = outcome.referenceGlucoseMgdl,
              let value = LowSoonAlertPolicy.validatedPrediction(from: outcome,
                expectedReferenceDate: reference, expectedSensorID: outcome.result.referenceSensorID,
                expectedGlucoseMgdl: glucose, at: now) else { return nil }
        return value.currentMgdl < LowSoonAlertPolicy.currentMinimumMgdl ||
            LowSoonAlertPolicy.condition(currentMgdl: value.currentMgdl, minimumMgdl: value.minimumMgdl)
    }

    private func fresh(_ sample: GlucoseForecastSample, at now: Date) -> Bool {
        sample.date.timeIntervalSince1970.isFinite && (0...330).contains(now.timeIntervalSince(sample.date)) &&
            sample.glucoseMgdl.isFinite && (20...600).contains(sample.glucoseMgdl) &&
            !(sample.sensorID ?? "").isEmpty
    }

    private func latestGlucose() -> GlucoseForecastSample? {
        if let override = inputOverrides.latestGlucose { return override() }
        guard let coreDataManager,
              let reading = BgReadingsAccessor(coreDataManager: coreDataManager)
                .getLatestBgReadingSnapshots(limit: 1, fromDate: nil, forSensor: nil,
                    ignoreRawData: true, ignoreCalculatedValue: true).first,
              reading.isValidForDownstream else { return nil }
        return .init(date: reading.timeStamp, glucoseMgdl: reading.finalValue, sensorID: reading.sensorID)
    }

    private func currentRules(at now: Date) -> MealQuietRules? {
        if let override = inputOverrides.currentRules { return override(now) }
        guard let context = coreDataManager?.mainManagedObjectContext else { return nil }
        let request: NSFetchRequest<AlertEntry> = AlertEntry.fetchRequest()
        request.predicate = NSPredicate(format: "alertkind IN %@", [AlertKind.low.rawValue, AlertKind.high.rawValue, AlertKind.veryhigh.rawValue])
        guard let entries = try? context.fetch(request) else { return nil }
        let minute = Int16(now.minutesSinceMidNightLocalTime())
        func threshold(_ kind: AlertKind) -> Double? {
            let rows = entries.filter { $0.alertkind == kind.rawValue }.sorted { $0.start < $1.start }
            guard rows.first?.start == 0, Set(rows.map(\.start)).count == rows.count,
                  let selected = rows.last(where: { $0.start <= minute }), !selected.isDisabled,
                  (selected.value(forKey: "alertType") as? AlertType)?.enabled == true else { return nil }
            return Double(selected.value)
        }
        guard let low = threshold(.low), let high = threshold(.high), let urgent = threshold(.veryhigh) else { return nil }
        let rules = MealQuietRules(low: low, high: high, urgentHigh: urgent,
                                   usesMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
        return rules.isValid ? rules : nil
    }

    private func pairLinkIsValid(_ record: MealQuietRecord) -> Bool {
        if let override = inputOverrides.pairIsValid { return override(record) }
        guard let metadata = try? MealPlanMetadataStore.shared.metadata(for: record.mealID) else { return false }
        return metadata.bolusUUID == record.bolusID
    }

    private func pairIsValid(_ record: MealQuietRecord) -> Bool {
        if let override = inputOverrides.pairIsValid { return override(record) }
        guard let coreDataManager, record.mealID != record.bolusID,
              let metadata = try? MealPlanMetadataStore.shared.metadata(for: record.mealID),
              metadata.bolusUUID == record.bolusID,
              let rows = try? MealPlanReminderCoordinator.storedTreatments(coreDataManager: coreDataManager,
                  uuids: [record.mealID, record.bolusID]), rows.count == 2,
              let meal = rows.first(where: { $0.uuid == record.mealID }),
              let bolus = rows.first(where: { $0.uuid == record.bolusID }) else { return false }
        return meal.isConfirmedMeal && meal.value.isFinite && meal.value > 0 &&
            meal.date == record.eatingAt && bolus.type == .Insulin && !bolus.deleted &&
            bolus.value.isFinite && bolus.value > 0
    }

    private func forecast(coreDataManager: CoreDataManager, at now: Date) async -> GlucoseForecastSafetyOutcome {
        if let override = inputOverrides.forecast { return await override(coreDataManager, now) }
        return await GlucoseForecastDataAdapter(coreDataManager: coreDataManager)
            .engineOnlyForecast(horizonMinutes: 60, at: now)
    }

    private func refreshRestoredSafety() {
        guard let coreDataManager, let active = document.active, let token = inputRevisionToken() else { return }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await forecast(coreDataManager: coreDataManager, at: clock())
            guard !Task.isCancelled, document.active?.mealID == active.mealID else { return }
            acceptSafetyOutcome(outcome, token: token, at: clock())
        }
    }
}
