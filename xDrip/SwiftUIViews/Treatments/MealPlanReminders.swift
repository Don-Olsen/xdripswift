import CoreData
import Foundation
import UserNotifications

/// Local coordination data only. Core Data remains the sole source of treatments and IOB/COB.
struct MealPlanMetadata: Codable, Equatable {
    let mealUUID: String
    var bolusUUID: String?
    let loggedAt: Date
    var plannedAt: Date?
    var followupAt: Date?
    var lastStoredMealDate: Date?
    var lastStoredMealGrams: Double?
    let pizzaPercentageNow: Int?
    let pizzaReminderMinutes: Int?
    var pizzaReminderEligible: Bool?
    var pizzaReminderAt: Date?

    init(mealUUID: String, bolusUUID: String?, loggedAt: Date, plannedAt: Date?, grams: Double,
         pizzaSettings: PizzaSplitSettings?, mealKind: TreatmentMealKind) {
        self.mealUUID = mealUUID
        self.bolusUUID = bolusUUID
        self.loggedAt = loggedAt
        self.plannedAt = plannedAt
        self.followupAt = plannedAt.flatMap { bolusUUID == nil ? nil : $0.addingTimeInterval(15 * 60) }
        self.lastStoredMealDate = plannedAt ?? loggedAt
        self.lastStoredMealGrams = grams
        let split = pizzaSettings?.isEnabled == true && mealKind == .slow
        self.pizzaPercentageNow = split ? pizzaSettings?.percentageNow : nil
        self.pizzaReminderMinutes = split ? pizzaSettings?.reminderMinutes : nil
        self.pizzaReminderEligible = split
        self.pizzaReminderAt = plannedAt == nil && split
            ? loggedAt.addingTimeInterval(TimeInterval((pizzaSettings?.reminderMinutes ?? 0) * 60)) : nil
    }

    func matchesLogAttempt(_ other: Self) -> Bool {
        mealUUID == other.mealUUID && bolusUUID == other.bolusUUID && loggedAt == other.loggedAt &&
            plannedAt == other.plannedAt && lastStoredMealGrams == other.lastStoredMealGrams &&
            pizzaPercentageNow == other.pizzaPercentageNow &&
            pizzaReminderMinutes == other.pizzaReminderMinutes
    }

    static func pizzaDueAt(actualMealAt: Date, confirmedAt: Date, intervalMinutes: Int) -> Date {
        max(actualMealAt.addingTimeInterval(TimeInterval(intervalMinutes * 60)),
            confirmedAt.addingTimeInterval(15 * 60))
    }
}

/// A per-meal atomic file is staged before a calculator treatment save. A crash can leave an
/// orphan file, but cannot leave a verified planned treatment without its selected settings.
@MainActor final class MealPlanMetadataStore {
    enum StoreError: Error { case invalidIdentity, conflictingOperation, unreadable, writeFailed }
    static let shared = MealPlanMetadataStore()

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = root.appendingPathComponent("PenDose/MealPlans", isDirectory: true)
    }

    func metadata(for uuid: String) throws -> MealPlanMetadata? {
        let url = try fileURL(for: uuid)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let metadata = try JSONDecoder().decode(MealPlanMetadata.self, from: Data(contentsOf: url))
            guard metadata.mealUUID == uuid else { throw StoreError.unreadable }
            return metadata
        } catch { throw StoreError.unreadable }
    }

    func stage(_ metadata: MealPlanMetadata) throws {
        if let existing = try self.metadata(for: metadata.mealUUID) {
            guard existing.matchesLogAttempt(metadata) else { throw StoreError.conflictingOperation }
            return
        }
        try replace(metadata)
    }

    func replace(_ metadata: MealPlanMetadata) throws {
        let url = try fileURL(for: metadata.mealUUID)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: directory.path)
            try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            handle.synchronizeFile()
            try handle.close()
        } catch { throw StoreError.writeFailed }
    }

    func remove(uuid: String) throws {
        let url = try fileURL(for: uuid)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func allMetadata() throws -> [MealPlanMetadata] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            guard let value = try metadata(for: url.deletingPathExtension().lastPathComponent) else {
                throw StoreError.unreadable
            }
            return value
        }
    }

    private func fileURL(for uuid: String) throws -> URL {
        guard let parsed = UUID(uuidString: uuid), parsed.uuidString == uuid.uppercased() else {
            throw StoreError.invalidIdentity
        }
        return directory.appendingPathComponent(uuid + ".json")
    }
}

/// A successful fresh-store read is required before metadata cleanup or notification updates.
@MainActor enum MealPlanReminderCoordinator {
    struct StoredTreatment {
        let uuid: String
        let type: TreatmentType
        let value: Double
        let date: Date
        let deleted: Bool
        let mealState: TreatmentMealState?
        let mealKind: TreatmentMealKind

        init(_ entry: TreatmentEntry) {
            uuid = entry.localTreatmentUUID ?? ""
            type = entry.treatmentType
            value = entry.value
            date = entry.date
            deleted = entry.treatmentdeleted
            mealState = entry.plannedMealStateRaw.flatMap(TreatmentMealState.init(rawValue:))
            mealKind = entry.mealKind
        }

        var isPlannedMeal: Bool { type == .Carbs && mealState == .planned && !deleted }
        var isConfirmedMeal: Bool { type == .Carbs && (mealState == nil || mealState == .confirmed) && !deleted }
    }

    enum MealStatus: Equatable { case planned, confirmed, cancelled, deleted, unavailable }

    static func storedTreatments(coreDataManager: CoreDataManager, uuids: [String]) throws -> [StoredTreatment] {
        guard let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator else {
            throw MealPlanMetadataStore.StoreError.unreadable
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var rows: [StoredTreatment] = []
        var readError: Error?
        context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "localTreatmentUUID IN %@", uuids)
            do { rows = try context.fetch(request).map(StoredTreatment.init) }
            catch { readError = error }
        }
        if let readError { throw readError }
        return rows
    }

    static func status(coreDataManager: CoreDataManager, uuid: String) -> MealStatus {
        guard let rows = try? storedTreatments(coreDataManager: coreDataManager, uuids: [uuid]) else {
            return .unavailable
        }
        guard let meal = rows.first(where: { $0.uuid == uuid && $0.type == .Carbs }) else { return .deleted }
        if meal.deleted { return .deleted }
        if meal.isPlannedMeal { return .planned }
        if meal.isConfirmedMeal { return .confirmed }
        return .cancelled
    }

    /// Called only after the treatment/journal has verified the permanent store.
    @discardableResult
    static func refresh(coreDataManager: CoreDataManager, mealUUID: String,
                        confirmedAt: Date? = nil, now: Date = .now,
                        store: MealPlanMetadataStore? = nil,
                        onIssue: ((String) -> Void)? = nil) -> String? {
        let store = store ?? .shared
        do {
            let rows = try storedTreatments(coreDataManager: coreDataManager, uuids: [mealUUID])
            guard let meal = rows.first(where: { $0.uuid == mealUUID && $0.type == .Carbs && !$0.deleted }) else {
                PlannedMealReminder.cancel(uuid: mealUUID)
                PizzaSplitReminder.cancel(uuid: mealUUID)
                try store.remove(uuid: mealUUID)
                return nil
            }
            var metadata = try store.metadata(for: mealUUID) ?? MealPlanMetadata(
                mealUUID: mealUUID, bolusUUID: nil, loggedAt: meal.date,
                plannedAt: meal.isPlannedMeal ? meal.date : nil, grams: meal.value,
                pizzaSettings: nil, mealKind: meal.mealKind)
            let savedMealDateChanged = metadata.lastStoredMealDate != nil &&
                metadata.lastStoredMealDate != meal.date
            let savedMealAmountChanged = metadata.lastStoredMealGrams != nil &&
                metadata.lastStoredMealGrams != meal.value
            let linkedBolus = try metadata.bolusUUID.flatMap { bolusUUID -> StoredTreatment? in
                try storedTreatments(coreDataManager: coreDataManager, uuids: [bolusUUID])
                    .first(where: { $0.uuid == bolusUUID && $0.type == .Insulin && !$0.deleted && $0.value > 0 })
            }
            if metadata.bolusUUID != nil && linkedBolus == nil { metadata.bolusUUID = nil }
            if meal.isPlannedMeal {
                if metadata.plannedAt != meal.date {
                    // Editing only moves a follow-up that has not already fallen due.
                    if let followupAt = metadata.followupAt, followupAt > now {
                        metadata.followupAt = metadata.bolusUUID == nil ? nil : meal.date.addingTimeInterval(15 * 60)
                    }
                    metadata.plannedAt = meal.date
                }
                if metadata.bolusUUID == nil { metadata.followupAt = nil }
                metadata.pizzaReminderAt = nil
                metadata.lastStoredMealDate = meal.date
                metadata.lastStoredMealGrams = meal.value
                try store.replace(metadata)
                PizzaSplitReminder.cancel(uuid: mealUUID)
                if meal.date > now, let request = PlannedMealReminder.request(
                    uuid: mealUUID, grams: meal.value, bolusUnits: linkedBolus?.value,
                    at: meal.date, now: now) {
                    PlannedMealReminder.schedule(request, mealUUID: mealUUID, coreDataManager: coreDataManager,
                        expectedDate: meal.date, expectedGrams: meal.value,
                        expectedBolus: linkedBolus?.value, expectedDue: meal.date,
                        store: store, onIssue: onIssue)
                }
                if let due = metadata.followupAt, due > now,
                   let bolus = linkedBolus,
                   let request = PlannedMealReminder.followupRequest(
                    uuid: mealUUID, bolusUnits: bolus.value, at: due, now: now) {
                    PlannedMealReminder.schedule(request, mealUUID: mealUUID, coreDataManager: coreDataManager,
                        expectedDate: meal.date, expectedGrams: meal.value,
                        expectedBolus: bolus.value, expectedDue: due,
                        store: store, onIssue: onIssue)
                } else if linkedBolus == nil {
                    PlannedMealReminder.cancelFollowup(uuid: mealUUID)
                }
            } else {
                PlannedMealReminder.cancel(uuid: mealUUID)
                if !meal.isConfirmedMeal {
                    PizzaSplitReminder.cancel(uuid: mealUUID)
                    try store.remove(uuid: mealUUID)
                    return nil
                }
                if savedMealDateChanged || savedMealAmountChanged {
                    PizzaSplitReminder.cancel(uuid: mealUUID)
                    if savedMealDateChanged, let oldDue = metadata.pizzaReminderAt,
                       oldDue > now, let interval = metadata.pizzaReminderMinutes {
                        metadata.pizzaReminderAt = MealPlanMetadata.pizzaDueAt(
                            actualMealAt: meal.date, confirmedAt: now, intervalMinutes: interval)
                    }
                }
                metadata.lastStoredMealDate = meal.date
                metadata.lastStoredMealGrams = meal.value
                if let interval = metadata.pizzaReminderMinutes,
                   metadata.pizzaPercentageNow != nil, metadata.pizzaReminderEligible != false,
                   meal.mealKind == .slow {
                    if metadata.pizzaReminderAt == nil {
                        let confirmedAt = confirmedAt ?? now
                        metadata.pizzaReminderAt = MealPlanMetadata.pizzaDueAt(
                            actualMealAt: meal.date, confirmedAt: confirmedAt, intervalMinutes: interval)
                    }
                    try store.replace(metadata)
                    if let due = metadata.pizzaReminderAt, due > now,
                       let request = PizzaSplitReminder.request(uuid: mealUUID, at: due, now: now) {
                        PizzaSplitReminder.schedule(request, mealUUID: mealUUID,
                            coreDataManager: coreDataManager, expectedDate: meal.date,
                            expectedDue: due, store: store, onIssue: onIssue)
                    }
                } else {
                    PizzaSplitReminder.cancel(uuid: mealUUID)
                    if meal.mealKind != .slow {
                        // A deliberate kind edit ends this meal's split. Retain the logged
                        // choice for audit, but do not revive its old request if edited back.
                        metadata.pizzaReminderEligible = false
                        metadata.pizzaReminderAt = nil
                    }
                    try store.replace(metadata)
                }
            }
            return nil
        } catch {
            return "Registreret – påmindelsen kunne ikke oprettes. Kontrollér måltidsplanen."
        }
    }

    static func refreshLinkedMeals(coreDataManager: CoreDataManager, bolusUUID: String,
                                   store: MealPlanMetadataStore? = nil,
                                   onIssue: ((String) -> Void)? = nil) {
        let store = store ?? .shared
        guard let metadata = try? store.allMetadata() else {
            onIssue?("Påmindelserne kunne ikke afstemmes. Kontrollér måltidsplanen.")
            return
        }
        for item in metadata where item.bolusUUID == bolusUUID {
            if let warning = refresh(coreDataManager: coreDataManager, mealUUID: item.mealUUID,
                                     store: store, onIssue: onIssue) { onIssue?(warning) }
        }
    }

    static func reconcile(coreDataManager: CoreDataManager, journal: PenDoseLogJournal? = nil,
                          store: MealPlanMetadataStore? = nil,
                          onIssue: ((String) -> Void)? = nil) {
        let journal = journal ?? .shared
        let store = store ?? .shared
        guard let metadata = try? store.allMetadata() else {
            onIssue?("Måltidsplanernes metadata kunne ikke læses.")
            return
        }
        for item in metadata {
            // An unacknowledged operation can still become durable after this read.
            if journal.recoveryState(coreDataManager: coreDataManager) != .ready,
               status(coreDataManager: coreDataManager, uuid: item.mealUUID) == .deleted { continue }
            if let warning = refresh(coreDataManager: coreDataManager, mealUUID: item.mealUUID,
                                     store: store, onIssue: onIssue) { onIssue?(warning) }
        }
    }
}

private enum MealNotificationRequest {
    static func add(_ request: UNNotificationRequest, isStillCurrent: @escaping () -> Bool,
                    onStale: @escaping () -> Void, onIssue: ((String) -> Void)?) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard isStillCurrent() else { return }
                guard settings.authorizationStatus == .authorized ||
                        settings.authorizationStatus == .provisional ||
                        settings.authorizationStatus == .ephemeral else {
                    onIssue?("Påmindelsen kunne ikke oprettes. Tillad notifikationer for xDrip i iOS-indstillinger.")
                    return
                }
                center.add(request) { error in
                    DispatchQueue.main.async {
                        if !isStillCurrent() {
                            // An older add callback can arrive after a newer request with the
                            // same stable identifier. Never remove by that identifier here:
                            // re-read the saved plan and let its current request replace ours.
                            onStale()
                        } else if error != nil {
                            onIssue?("Påmindelsen kunne ikke oprettes. Kontrollér notifikationsindstillingerne.")
                        }
                    }
                }
            }
        }
    }
}

private enum MealReminderNumber {
    static func text(_ value: Double, minimumFractionDigits: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = 4
        formatter.minusSign = "−"
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }
}

enum MealReminderIssueCenter {
    static let reported = Notification.Name("xdrip.mealReminder.issueReported")
    static func report(_ message: String) {
        NotificationCenter.default.post(name: reported, object: message)
    }
}

/// A notification asks for confirmation; it never makes a planned meal count as eaten.
enum PlannedMealReminder {
    static let identifierPrefix = "xdrip.plannedMeal."
    static let openRequested = Notification.Name("xdrip.plannedMeal.openRequested")
    static let uuidUserInfoKey = "plannedMealUUID"
    private static let pendingOpenKey = "plannedMealPendingOpenUUID"

    static func identifier(for uuid: String) -> String { identifierPrefix + "meal." + uuid }
    static func followupIdentifier(for uuid: String) -> String { identifierPrefix + "followup." + uuid }

    static func request(uuid: String, grams: Double, bolusUnits: Double?, at date: Date,
                        now: Date = .now, locale: Locale = .current) -> UNNotificationRequest? {
        let interval = date.timeIntervalSince(now)
        guard UUID(uuidString: uuid) != nil, grams.isFinite, grams > 0,
              interval > 0, interval <= TreatmentEditorViewModel.maximumFutureTreatmentInterval else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "Tid til at spise"
        let gramsText = MealReminderNumber.text(grams, minimumFractionDigits: 0, locale: locale)
        if let bolusUnits, bolusUnits.isFinite, bolusUnits > 0 {
            let insulinText = MealReminderNumber.text(bolusUnits, minimumFractionDigits: 1, locale: locale)
            content.body = "Du har registreret \(insulinText) E til \(gramsText) g. Tryk og bekræft, når du spiser."
        } else {
            content.body = "\(gramsText) g er planlagt nu. Tryk og bekræft, når du spiser."
        }
        content.sound = .default
        content.userInfo = [uuidUserInfoKey: uuid]
        return UNNotificationRequest(identifier: identifier(for: uuid), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
    }

    static func followupRequest(uuid: String, bolusUnits: Double, at date: Date,
                                now: Date = .now, locale: Locale = .current) -> UNNotificationRequest? {
        let interval = date.timeIntervalSince(now)
        guard UUID(uuidString: uuid) != nil, bolusUnits.isFinite, bolusUnits > 0, interval > 0 else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "Har du spist?"
        let insulinText = MealReminderNumber.text(bolusUnits, minimumFractionDigits: 1, locale: locale)
        content.body = "Du har registreret \(insulinText) E, men måltidet er ikke bekræftet. Åbn xDrip og kontrollér planen."
        content.sound = .default
        content.userInfo = [uuidUserInfoKey: uuid]
        return UNNotificationRequest(identifier: followupIdentifier(for: uuid), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
    }

    @MainActor static func schedule(_ request: UNNotificationRequest, mealUUID: String,
                                    coreDataManager: CoreDataManager, expectedDate: Date,
                                    expectedGrams: Double, expectedBolus: Double?, expectedDue: Date,
                                    store: MealPlanMetadataStore,
                                    onIssue: ((String) -> Void)? = nil) {
        MealNotificationRequest.add(request, isStillCurrent: {
            guard case .planned = MealPlanReminderCoordinator.status(coreDataManager: coreDataManager,
                                                                      uuid: mealUUID),
                  let rows = try? MealPlanReminderCoordinator.storedTreatments(
                    coreDataManager: coreDataManager, uuids: [mealUUID]),
                  let metadata = try? store.metadata(for: mealUUID),
                  let meal = rows.first(where: { $0.uuid == mealUUID }),
                  meal.date == expectedDate, meal.value == expectedGrams else { return false }
            let currentBolusUnits: Double?
            if let uuid = metadata.bolusUUID {
                guard let bolusRows = try? MealPlanReminderCoordinator.storedTreatments(
                    coreDataManager: coreDataManager, uuids: [uuid]) else { return false }
                currentBolusUnits = bolusRows.first(where: {
                    $0.uuid == uuid && $0.type == .Insulin && !$0.deleted && $0.value > 0
                })?.value
            } else {
                currentBolusUnits = nil
            }
            guard currentBolusUnits == expectedBolus else { return false }
            return request.identifier == followupIdentifier(for: mealUUID)
                ? metadata.followupAt == expectedDue : metadata.plannedAt == expectedDue
        }, onStale: {
            if let warning = MealPlanReminderCoordinator.refresh(coreDataManager: coreDataManager,
                mealUUID: mealUUID, store: store, onIssue: onIssue) { onIssue?(warning) }
        }, onIssue: onIssue)
    }

    static func cancelFollowup(uuid: String) {
        let id = followupIdentifier(for: uuid)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    static func cancel(uuid: String) {
        let ids = [identifier(for: uuid), followupIdentifier(for: uuid)]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func tappedUUID(from request: UNNotificationRequest) -> String? {
        guard let uuid = request.content.userInfo[uuidUserInfoKey] as? String,
              UUID(uuidString: uuid) != nil,
              request.identifier == identifier(for: uuid) ||
                request.identifier == followupIdentifier(for: uuid) else { return nil }
        return uuid
    }

    static func recordTap(uuid: String) {
        UserDefaults.standard.set(uuid, forKey: pendingOpenKey)
        NotificationCenter.default.post(name: openRequested, object: nil)
    }

    static var pendingOpenUUID: String? { UserDefaults.standard.string(forKey: pendingOpenKey) }
    static func clearPendingOpenUUID(_ uuid: String) {
        guard pendingOpenUUID == uuid else { return }
        UserDefaults.standard.removeObject(forKey: pendingOpenKey)
    }
}

/// The 🍕 request opens a fresh calculation; its saved date never shifts on restart.
enum PizzaSplitReminder {
    static let identifierPrefix = "xdrip.pizzaSplit."
    static let uuidUserInfoKey = "pizzaMealUUID"
    static let openRequested = Notification.Name("xdrip.pizzaSplit.openRequested")
    private static let pendingOpenKey = "pizzaSplitPendingOpenUUID"

    static func identifier(for uuid: String) -> String { identifierPrefix + uuid }

    static func request(uuid: String, at date: Date, now: Date = .now) -> UNNotificationRequest? {
        let interval = date.timeIntervalSince(now)
        guard UUID(uuidString: uuid) != nil, interval > 0 else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "Tid til ny vurdering"
        content.body = "Åbn xDrip og beregn igen med aktuelle målinger. Tidligere forslag gælder ikke."
        content.sound = .default
        content.userInfo = [uuidUserInfoKey: uuid]
        return UNNotificationRequest(identifier: identifier(for: uuid), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
    }

    static func request(uuid: String, after minutes: Int, now: Date = .now) -> UNNotificationRequest? {
        guard (15...240).contains(minutes) else { return nil }
        return request(uuid: uuid, at: now.addingTimeInterval(TimeInterval(minutes * 60)), now: now)
    }

    @MainActor static func schedule(_ request: UNNotificationRequest, mealUUID: String,
                                    coreDataManager: CoreDataManager, expectedDate: Date,
                                    expectedDue: Date, store: MealPlanMetadataStore,
                                    onIssue: ((String) -> Void)? = nil) {
        MealNotificationRequest.add(request, isStillCurrent: {
            guard case .confirmed = MealPlanReminderCoordinator.status(coreDataManager: coreDataManager,
                                                                        uuid: mealUUID),
                  let rows = try? MealPlanReminderCoordinator.storedTreatments(
                    coreDataManager: coreDataManager, uuids: [mealUUID]),
                  let metadata = try? store.metadata(for: mealUUID),
                  let meal = rows.first(where: { $0.uuid == mealUUID }) else { return false }
            return meal.date == expectedDate && meal.mealKind == .slow &&
                metadata.pizzaReminderAt == expectedDue && metadata.pizzaPercentageNow != nil &&
                metadata.pizzaReminderEligible != false
        }, onStale: {
            if let warning = MealPlanReminderCoordinator.refresh(coreDataManager: coreDataManager,
                mealUUID: mealUUID, store: store, onIssue: onIssue) { onIssue?(warning) }
        }, onIssue: onIssue)
    }

    static func cancel(uuid: String) {
        let id = identifier(for: uuid)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    static func tappedUUID(from request: UNNotificationRequest) -> String? {
        guard let uuid = request.content.userInfo[uuidUserInfoKey] as? String,
              UUID(uuidString: uuid) != nil, request.identifier == identifier(for: uuid) else { return nil }
        return uuid
    }

    static func recordTap(uuid: String) {
        UserDefaults.standard.set(uuid, forKey: pendingOpenKey)
        NotificationCenter.default.post(name: openRequested, object: nil)
    }

    static var pendingOpenUUID: String? { UserDefaults.standard.string(forKey: pendingOpenKey) }
    static func clearPendingOpenUUID(_ uuid: String) {
        guard pendingOpenUUID == uuid else { return }
        UserDefaults.standard.removeObject(forKey: pendingOpenKey)
    }
}
