import Combine
import CoreData
import Foundation
import UserNotifications

struct BasalReminderSettings: Equatable {
    static let enabledKey = "basalReminderEnabled"
    static let minuteOfDayKey = "basalReminderMinuteOfDay"
    static let defaultMinuteOfDay = 20 * 60

    var isEnabled: Bool
    var minuteOfDay: Int

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let enabled = defaults.object(forKey: enabledKey) == nil ? false : defaults.bool(forKey: enabledKey)
        let storedMinute = defaults.object(forKey: minuteOfDayKey) as? Int ?? defaultMinuteOfDay
        return Self(isEnabled: enabled, minuteOfDay: (0..<24 * 60).contains(storedMinute) ? storedMinute : defaultMinuteOfDay)
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(minuteOfDay, forKey: Self.minuteOfDayKey)
    }
}

struct BasalReminderInjection: Equatable {
    let date: Date
    let units: Int
    let insulinDescription: String

    init?(date: Date, units: Double, insulinDescription: String?) {
        guard units.isFinite, units > 0, let whole = Int(exactly: units) else { return nil }
        self.date = date
        self.units = whole
        self.insulinDescription = (insulinDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var historyText: String {
        let name = insulinDescription.isEmpty ? "" : " \(insulinDescription)"
        return "Senest registreret: \(units) E\(name)"
    }
}

enum BasalReminderPlanner {
    /// Fourteen one-shot calendar requests keep delivery independent of app launch while leaving
    /// room for the app's existing glucose alarms and meal reminders in iOS's pending queue.
    static let horizonDays = 14
    static let recentInjectionInterval: TimeInterval = 12 * 60 * 60

    struct Occurrence: Equatable {
        let dayKey: String
        let dueAt: Date
        let lastInjection: BasalReminderInjection?
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func dueDate(on day: Date, minuteOfDay: Int, calendar: Calendar) -> Date? {
        guard (0..<24 * 60).contains(minuteOfDay) else { return nil }
        let start = calendar.startOfDay(for: day)
        let match = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        guard let due = calendar.nextDate(after: start.addingTimeInterval(-1), matching: match,
                                          matchingPolicy: .nextTime, repeatedTimePolicy: .first),
              calendar.isDate(due, inSameDayAs: start) else { return nil }
        return due
    }

    static func hasRecentInjection(for dueAt: Date, injections: [BasalReminderInjection]) -> Bool {
        injections.contains { $0.date >= dueAt.addingTimeInterval(-recentInjectionInterval) && $0.date <= dueAt }
    }

    static func canSnooze(dayKey: String, dueAt: Date, now: Date,
                          alreadySnoozed: Set<String>, injections: [BasalReminderInjection]) -> Bool {
        !alreadySnoozed.contains(dayKey) && dueAt <= now &&
            now < dueAt.addingTimeInterval(24 * 60 * 60) &&
            !hasRecentInjection(for: dueAt, injections: injections) &&
            !injections.contains { $0.date > dueAt && $0.date <= now }
    }

    static func plan(now: Date, settings: BasalReminderSettings,
                     injections: [BasalReminderInjection], calendar: Calendar,
                     horizonDays: Int = horizonDays) -> [Occurrence] {
        guard settings.isEnabled, horizonDays > 0 else { return [] }
        let knownHistory = injections.filter { $0.date <= now }.sorted { $0.date > $1.date }
        let start = calendar.startOfDay(for: now)
        return (0..<horizonDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let dueAt = dueDate(on: day, minuteOfDay: settings.minuteOfDay, calendar: calendar),
                  dueAt > now, !hasRecentInjection(for: dueAt, injections: injections) else { return nil }
            return Occurrence(dayKey: dayKey(for: day, calendar: calendar),
                              dueAt: dueAt, lastInjection: knownHistory.first)
        }
    }
}

enum BasalReminderPermission {
    static func isAvailable(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }
}

/// Keep a notification action received during a cold launch until the treatment store is ready.
enum BasalReminderPendingSnoozes {
    private static let key = "basalReminderPendingSnoozes"

    static func load(defaults: UserDefaults = .standard) -> [String: Date] {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return raw.compactMapValues { value in
            guard let time = value as? TimeInterval, time.isFinite else { return nil }
            return Date(timeIntervalSince1970: time)
        }
    }

    static func enqueue(dayKey: String, dueAt: Date, defaults: UserDefaults = .standard) {
        guard dueAt.timeIntervalSince1970.isFinite else { return }
        var pending = load(defaults: defaults)
        guard pending[dayKey] == nil else { return }
        pending[dayKey] = dueAt
        defaults.set(pending.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    static func remove(dayKey: String, defaults: UserDefaults = .standard) {
        var pending = load(defaults: defaults)
        pending[dayKey] = nil
        defaults.set(pending.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}

/// Uses the app's existing notification center and Core Data store. Only identifiers beginning
/// with `xdrip.basalReminder.` are ever changed here.
@MainActor final class BasalReminderScheduler: ObservableObject {
    static let shared = BasalReminderScheduler()
    static let identifierPrefix = "xdrip.basalReminder."
    static let dailyPrefix = identifierPrefix + "day."
    static let snoozePrefix = identifierPrefix + "snooze."
    static let categoryIdentifier = "xdrip.basalReminder.actions"
    static let snoozeActionIdentifier = "xdrip.basalReminder.snooze30"
    static let openRequested = Notification.Name("xdrip.basalReminder.openRequested")
    private static let pendingOpenKey = "basalReminderPendingOpen"
    private static let snoozedDaysKey = "basalReminderSnoozedDays"

    private weak var coreDataManager: CoreDataManager?
    @Published private(set) var issueMessage: String?
    private var refreshRevision = 0
    private var refreshTask: Task<Void, Never>?
    private var snoozesInFlight = Set<String>()

    static func dailyIdentifier(for dayKey: String) -> String { dailyPrefix + dayKey }
    static func snoozeIdentifier(for dayKey: String) -> String { snoozePrefix + dayKey }

    func configure(coreDataManager: CoreDataManager) {
        self.coreDataManager = coreDataManager
        registerCategory()
        processPendingSnoozes()
        refresh()
    }

    func refreshAfterTreatmentChange(coreDataManager: CoreDataManager, savedBasalAt: Date? = nil) {
        guard self.coreDataManager === coreDataManager else { return }
        if let savedBasalAt {
            // The expected day may be today or tomorrow when a dose is logged late at night.
            // Cancel before a new calendar plan is read; the fresh read will restore any day
            // that is still eligible after this verified treatment save.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            let today = calendar.startOfDay(for: savedBasalAt)
            let days = [calendar.date(byAdding: .day, value: -1, to: today),
                        today, calendar.date(byAdding: .day, value: 1, to: today)].compactMap { $0 }
            let ids = days.flatMap { day -> [String] in
                let key = BasalReminderPlanner.dayKey(for: day, calendar: calendar)
                return [Self.dailyIdentifier(for: key), Self.snoozeIdentifier(for: key)]
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
        refresh()
    }

    func refresh() {
        processPendingSnoozes()
        refreshRevision += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var completedRevision = 0
            while completedRevision != self.refreshRevision {
                completedRevision = self.refreshRevision
                await self.reconcile(revision: completedRevision)
            }
            self.refreshTask = nil
        }
    }

    private func reconcile(revision: Int) async {
        guard let coreDataManager else { return }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let settings = BasalReminderSettings.load()
        let injections: [BasalReminderInjection]
        do { injections = try Self.storedInjections(coreDataManager: coreDataManager) }
        catch {
            issueMessage = "Registrerede basaldoser kunne ikke læses. Påmindelsen er ikke opdateret."
            return // Never cancel a valid reminder based on an unreadable store.
        }
        let plan = BasalReminderPlanner.plan(now: now, settings: settings,
                                             injections: injections, calendar: calendar)
        let center = UNUserNotificationCenter.current()
        let pending = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
        let delivered = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { continuation.resume(returning: $0) }
        }
        guard revision == refreshRevision else { return }

        let deliveredIDs = Set(delivered.map { $0.request.identifier })
        let snoozedDays = Set(UserDefaults.standard.stringArray(forKey: Self.snoozedDaysKey) ?? [])
        let eligiblePlan = plan.filter { occurrence in
            let id = Self.dailyIdentifier(for: occurrence.dayKey)
            return !deliveredIDs.contains(id) && !snoozedDays.contains(occurrence.dayKey)
        }
        let plannedByID = Dictionary(uniqueKeysWithValues: eligiblePlan.map { (Self.dailyIdentifier(for: $0.dayKey), $0) })
        let pendingDaily = pending.filter { $0.identifier.hasPrefix(Self.dailyPrefix) }
        let obsoleteDaily = pendingDaily.filter { request in
            guard let occurrence = plannedByID[request.identifier] else { return true }
            return !Self.matches(request, occurrence: occurrence, calendar: calendar)
        }
        let obsoleteDailyIDs = obsoleteDaily.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsoleteDailyIDs)
        if !settings.isEnabled {
            let snoozeIDs = pending.map(\.identifier).filter { $0.hasPrefix(Self.snoozePrefix) }
            center.removePendingNotificationRequests(withIdentifiers: snoozeIDs)
            center.removeDeliveredNotifications(withIdentifiers: Array(deliveredIDs.filter {
                $0.hasPrefix(Self.identifierPrefix)
            }))
            issueMessage = nil
            return
        }

        let pendingSnoozes = pending.filter { $0.identifier.hasPrefix(Self.snoozePrefix) }
        let staleSnoozes = pendingSnoozes.filter { request in
            guard let dueAt = request.content.userInfo["basalDueAt"] as? Date else { return true }
            return BasalReminderPlanner.hasRecentInjection(for: dueAt, injections: injections) ||
                injections.contains { $0.date > dueAt && $0.date <= now }
        }
        let staleIDs = staleSnoozes.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        center.removeDeliveredNotifications(withIdentifiers: staleIDs)

        var addFailed = false
        for occurrence in eligiblePlan {
            guard revision == refreshRevision else { return }
            let request = Self.dailyRequest(for: occurrence, calendar: calendar)
            if pendingDaily.contains(where: {
                $0.identifier == request.identifier && Self.matches($0, occurrence: occurrence, calendar: calendar)
            }) { continue }
            let added: Bool = await withCheckedContinuation { continuation in
                center.add(request) { error in
                    continuation.resume(returning: error == nil)
                }
            }
            if !added { addFailed = true }
        }
        issueMessage = addFailed ? "Basalpåmindelsen kunne ikke planlægges. Prøv igen." : nil
    }

    private static func matches(_ request: UNNotificationRequest,
                                occurrence: BasalReminderPlanner.Occurrence,
                                calendar: Calendar) -> Bool {
        let expected = dailyRequest(for: occurrence, calendar: calendar)
        guard let stored = request.trigger as? UNCalendarNotificationTrigger,
              let desired = expected.trigger as? UNCalendarNotificationTrigger else { return false }
        return request.content.title == expected.content.title &&
            request.content.body == expected.content.body &&
            request.content.categoryIdentifier == expected.content.categoryIdentifier &&
            request.content.userInfo["basalDueAt"] as? Date == occurrence.dueAt &&
            stored.dateComponents.year == desired.dateComponents.year &&
            stored.dateComponents.month == desired.dateComponents.month &&
            stored.dateComponents.day == desired.dateComponents.day &&
            stored.dateComponents.hour == desired.dateComponents.hour &&
            stored.dateComponents.minute == desired.dateComponents.minute &&
            stored.dateComponents.timeZone == desired.dateComponents.timeZone
    }

    static func dailyRequest(for occurrence: BasalReminderPlanner.Occurrence,
                             calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Husk basal"
        content.body = occurrence.lastInjection?.historyText ?? "Registrér din basaldosis i xDrip."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["basalDayKey": occurrence.dayKey, "basalDueAt": occurrence.dueAt]
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence.dueAt)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: dailyIdentifier(for: occurrence.dayKey), content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    func handleResponse(_ response: UNNotificationResponse) -> Bool {
        let request = response.notification.request
        guard request.identifier.hasPrefix(Self.identifierPrefix),
              let dayKey = request.content.userInfo["basalDayKey"] as? String,
              request.identifier == Self.dailyIdentifier(for: dayKey) ||
                request.identifier == Self.snoozeIdentifier(for: dayKey) else { return false }
        if response.actionIdentifier == Self.snoozeActionIdentifier {
            guard request.identifier == Self.dailyIdentifier(for: dayKey),
                  let dueAt = request.content.userInfo["basalDueAt"] as? Date else { return true }
            BasalReminderPendingSnoozes.enqueue(dayKey: dayKey, dueAt: dueAt)
            processPendingSnoozes()
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Self.recordTap()
        }
        return true
    }

    private func processPendingSnoozes() {
        let pending = BasalReminderPendingSnoozes.load()
        guard !pending.isEmpty, let coreDataManager else { return }
        let defaults = UserDefaults.standard
        guard let injections = try? Self.storedInjections(coreDataManager: coreDataManager) else {
            issueMessage = "Registrerede basaldoser kunne ikke læses. Udsættelsen afventer."
            return
        }
        let snoozed = Set(defaults.stringArray(forKey: Self.snoozedDaysKey) ?? [])
        for (dayKey, dueAt) in pending {
            guard !snoozesInFlight.contains(dayKey) else { continue }
            guard BasalReminderSettings.load().isEnabled,
                  BasalReminderPlanner.canSnooze(dayKey: dayKey, dueAt: dueAt, now: Date(),
                                                  alreadySnoozed: snoozed, injections: injections) else {
                BasalReminderPendingSnoozes.remove(dayKey: dayKey)
                continue
            }
            snoozesInFlight.insert(dayKey)
            let content = UNMutableNotificationContent()
            content.title = "Husk basal"
            content.body = injections.filter { $0.date <= Date() }.max(by: { $0.date < $1.date })?.historyText
                ?? "Registrér din basaldosis i xDrip."
            content.sound = .default
            content.userInfo = ["basalDayKey": dayKey, "basalDueAt": dueAt]
            let request = UNNotificationRequest(identifier: Self.snoozeIdentifier(for: dayKey), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false))
            UNUserNotificationCenter.current().add(request) { error in
                Task { @MainActor in
                    self.snoozesInFlight.remove(dayKey)
                    if error == nil {
                        var completed = Set(defaults.stringArray(forKey: Self.snoozedDaysKey) ?? [])
                        completed.insert(dayKey)
                        defaults.set(Array(completed).sorted(), forKey: Self.snoozedDaysKey)
                        BasalReminderPendingSnoozes.remove(dayKey: dayKey)
                    } else {
                        self.issueMessage = "Udsættelsen kunne ikke planlægges. Prøv igen."
                    }
                }
            }
        }
    }

    private func registerCategory() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { categories in
            let action = UNNotificationAction(identifier: Self.snoozeActionIdentifier,
                                              title: "Udsæt 30 min", options: [])
            let category = UNNotificationCategory(identifier: Self.categoryIdentifier,
                                                  actions: [action], intentIdentifiers: [], options: [])
            var updated = Set(categories.filter { $0.identifier != Self.categoryIdentifier })
            updated.insert(category)
            center.setNotificationCategories(updated)
        }
    }

    static func storedInjections(coreDataManager: CoreDataManager) throws -> [BasalReminderInjection] {
        guard let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator else {
            throw BasalReminderStoreError.unavailable
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var injections: [BasalReminderInjection] = []
        var readError: Error?
        context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "treatmentType == %d AND (treatmentdeleted == NO OR treatmentdeleted == nil)",
                                             TreatmentType.BasalInjection.rawValue)
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(TreatmentEntry.date), ascending: false)]
            do {
                injections = try context.fetch(request).compactMap {
                    BasalReminderInjection(date: $0.date, units: $0.value, insulinDescription: $0.notes)
                }
            } catch { readError = error }
        }
        if let readError { throw readError }
        return injections
    }

    /// The reminder opens the existing editor with a draft based on the newest *stored* basal.
    /// This is a prefill preference only; opening the editor never writes a treatment.
    static func prepareDraftPrefill(coreDataManager: CoreDataManager, now: Date = .now) -> Bool {
        guard let injections = try? storedInjections(coreDataManager: coreDataManager) else { return false }
        let latest = injections.first { $0.date <= now }
        UserDefaults.standard.lastBasalInjectionUnits = latest?.units ?? 0
        UserDefaults.standard.lastBasalInjectionInsulinDescription = latest?.insulinDescription ?? ""
        return true
    }

    private enum BasalReminderStoreError: Error { case unavailable }

    static var hasPendingOpen: Bool { UserDefaults.standard.bool(forKey: pendingOpenKey) }
    static func recordTap() {
        UserDefaults.standard.set(true, forKey: pendingOpenKey)
        NotificationCenter.default.post(name: openRequested, object: nil)
    }
    static func consumePendingOpen() -> Bool {
        guard hasPendingOpen else { return false }
        UserDefaults.standard.removeObject(forKey: pendingOpenKey)
        return true
    }
}
