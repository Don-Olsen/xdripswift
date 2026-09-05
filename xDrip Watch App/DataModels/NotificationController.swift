//
//  NotificationController.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 24/5/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI
import UserNotifications

#if canImport(WatchKit)
import WatchKit

class NotificationController: WKUserNotificationHostingController<NotificationView> {
    var alertTitle: String?
    var bgReadingValues: [Double]?
    var bgReadingDates: [Date]?
    var isMgDl: Bool?
    var slopeOrdinal: Int?
    var deltaValueInUserUnit: Double?
    var urgentLowLimitInMgDl: Double?
    var lowLimitInMgDl: Double?
    var highLimitInMgDl: Double?
    var urgentHighLimitInMgDl: Double?
    var alertUrgencyType: AlertUrgencyType?
    
    var bgUnitString: String?
    var bgValueInMgDl: Double?
    var bgReadingDate: Date?
    var bgValueStringInUserChosenUnit: String?
    
    override var body: NotificationView {
        NotificationView(
            alertTitle: alertTitle,
            bgReadingValues: bgReadingValues,
            bgReadingDates: bgReadingDates,
            isMgDl: isMgDl,
            slopeOrdinal: slopeOrdinal,
            deltaValueInUserUnit: deltaValueInUserUnit,
            urgentLowLimitInMgDl: urgentLowLimitInMgDl,
            lowLimitInMgDl: lowLimitInMgDl,
            highLimitInMgDl: highLimitInMgDl,
            urgentHighLimitInMgDl: urgentHighLimitInMgDl,
            alertUrgencyType: alertUrgencyType,
            bgUnitString: bgUnitString,
            bgValueInMgDl: bgValueInMgDl,
            bgReadingDate: bgReadingDate,
            bgValueStringInUserChosenUnit: bgValueStringInUserChosenUnit
        )
    }
    
    override func didReceive(_ notification: UNNotification) {
        // pull the userInfo dictionary from the received notification
        let userInfo = notification.request.content.userInfo
        
        // set the title label. This is common for all notifications
        alertTitle = userInfo["alertTitle"] as? String ?? ""
        
        // set the image and colours based upon the alertUrgencyType
        alertUrgencyType = AlertUrgencyType(rawValue: userInfo["alertUrgencyTypeRawValue"] as? Int ?? 0)
        
        bgReadingValues = userInfo["bgReadingValues"] as? [Double] ?? [0]
        isMgDl = userInfo["isMgDl"] as? Bool ?? true
        slopeOrdinal = userInfo["slopeOrdinal"] as? Int ?? 0
        deltaValueInUserUnit = userInfo["deltaValueInUserUnit"] as? Double ?? 0
        urgentLowLimitInMgDl = userInfo["urgentLowLimitInMgDl"] as? Double ?? 0
        lowLimitInMgDl = userInfo["lowLimitInMgDl"] as? Double ?? 0
        highLimitInMgDl = userInfo["highLimitInMgDl"] as? Double ?? 0
        urgentHighLimitInMgDl = userInfo["urgentHighLimitInMgDl"] as? Double ?? 0
        
        let bgReadingDatesFromDictionary: [Double] = userInfo["bgReadingDatesAsDouble"] as? [Double] ?? [0]
        bgReadingDates = bgReadingDatesFromDictionary.map { (bgReadingDateAsDouble) -> Date in
            return Date(timeIntervalSince1970: bgReadingDateAsDouble)
        }
        
        bgUnitString = isMgDl ?? true ? Texts_Common.mgdl : Texts_Common.mmol
        bgValueInMgDl = (bgReadingValues?.count ?? 0) > 0 ? bgReadingValues?[0] : nil
        bgReadingDate = (bgReadingDates?.count ?? 0) > 0 ? bgReadingDates?[0] : nil
        
        bgValueStringInUserChosenUnit = (bgReadingValues?.count ?? 0) > 0 ? bgReadingValues?[0].mgDlToMmolAndToString(mgDl: isMgDl ?? true) ?? "" : ""
        
    }
}
#endif

/// Local Watch alarms use only accepted direct readings and an explicitly delegated,
/// persisted copy of the user's real phone alert settings.
final class LibreWatchAlarmController: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var configuration = LibreWatchAlarmStore.configuration()
    var settings: LibreWatchAlarmSettings? { configuration.effectiveSettings }
    var offeredSettings: LibreWatchAlarmSettings? { configuration.offeredSettings }
    var hasPendingConfiguration: Bool { configuration.pendingSettings != nil }
    private(set) var state = LibreWatchAlarmStore.state()
    private var delegation: LibreWatchAlarmDelegation? { configuration.delegation }
    private var watchOwnsSensor = false
    private var notificationsAuthorized = false
    private var pendingGlucoseAlarm = false
    var onStatusChange: ((String) -> Void)?
    var onReadinessChange: (() -> Void)?
    var onSnooze: (() -> Void)?
    private let category = "libreWatchLocalAlarmSnooze"
    private let snoozeAction = "libreWatchLocalSnooze"

    var notificationsAreAuthorized: Bool { notificationsAuthorized }
    var alarmsAreDelegatedToWatch: Bool {
        watchOwnsSensor && settings.map { delegation?.matches($0) == true } == true
    }

    var readinessRevision: UInt64? {
        offeredSettings?.readinessRevision(notificationsAuthorized: notificationsAuthorized)
    }

    override init() {
        super.init()
        center.delegate = self
        center.getNotificationCategories { [weak self] categories in
            guard let self else { return }
            var updated = categories
            let action = UNNotificationAction(identifier: self.snoozeAction, title: "Snooze", options: [])
            updated.insert(UNNotificationCategory(identifier: self.category, actions: [action], intentIdentifiers: [], options: []))
            self.center.setNotificationCategories(updated)
        }
        refreshPermission()
    }

    func apply(settings candidate: LibreWatchAlarmSettings, session: LibreWatchDirectSession) {
        let previousRevision = readinessRevision
        guard configuration.propose(candidate, session: session), let committed = configuration.settings else { return }
        if state.sessionID != committed.sessionID { cancelScheduledAlarms() }
        state.use(committed)
        state.acknowledgePhoneSnoozes(committed)
        LibreWatchAlarmStore.save(configuration)
        LibreWatchAlarmStore.save(state)
        // Unconfirmed revisions do not delete the previous missed-reading deadline.
        // Only a confirmed change (or an explicit later snooze) changes its identity.
        scheduleMissedIfNeeded()
        publishStatus()
        if previousRevision != readinessRevision { onReadinessChange?() }
    }

    func validate(session: LibreWatchDirectSession?) {
        guard let session, settings?.matches(session) == true else {
            cancelScheduledAlarms()
            configuration = LibreWatchAlarmConfiguration()
            state = LibreWatchAlarmState()
            LibreWatchAlarmStore.clearSession()
            publishStatus()
            return
        }
    }

    func apply(delegation: LibreWatchAlarmDelegation?, session: LibreWatchDirectSession) {
        guard configuration.confirm(delegation, session: session) else { return }
        if let committed = configuration.settings {
            state.use(committed)
            state.acknowledgePhoneSnoozes(committed)
        }
        LibreWatchAlarmStore.save(configuration)
        LibreWatchAlarmStore.save(state)
        if delegation == nil { cancelScheduledAlarms() }
        scheduleMissedIfNeeded()
        publishStatus()
    }

    func ownershipDidChange(_ ownership: LibreWatchOwnership) {
        watchOwnsSensor = ownership == .watch
        if !watchOwnsSensor {
            state.endWatchOwnership()
            cancelScheduledAlarms()
        } else {
            state.beginWatchOwnership(at: Date())
            LibreWatchAlarmStore.save(state)
            scheduleMissedIfNeeded()
        }
        publishStatus()
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshPermission() }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { [weak self] permissions in
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.readinessRevision
                self.notificationsAuthorized = permissions.authorizationStatus == .authorized || permissions.authorizationStatus == .provisional
                if !self.notificationsAuthorized { self.cancelScheduledAlarms() }
                else { self.reconcileScheduledMissedAlarm() }
                self.publishStatus()
                if previous != self.readinessRevision { self.onReadinessChange?() }
            }
        }
    }

    func acceptedDirectReading(_ reading: LibreWatchDirectReadingPayload, glucose: Double, at now: Date = Date()) {
        guard let settings, readinessRevision != nil else { return }
        let rule = state.accept(id: reading.id, measuredAt: reading.receivedAt, glucose: glucose,
            settings: settings, delegation: delegation, watchOwnsSensor: watchOwnsSensor, now: now)
        LibreWatchAlarmStore.save(state)
        scheduleMissedIfNeeded(at: now)
        guard let rule, !pendingGlucoseAlarm else { return }
        pendingGlucoseAlarm = true
        let content = content(for: rule)
        content.body = "\(glucose.mgDlToMmolAndToString(mgDl: settings.isMgDl)) \(settings.isMgDl ? "mg/dL" : "mmol/L") · Direkte fra Libre · \(reading.receivedAt.formatted(date: .omitted, time: .shortened))"
        let request = UNNotificationRequest(identifier: identifier(for: rule.kind), content: content, trigger: nil)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingGlucoseAlarm = false
                guard self.state.glucoseNotificationIsCurrent(
                    readingID: reading.id, rule: rule, submittedSettings: settings,
                    currentSettings: self.settings, delegation: self.delegation,
                    watchOwnsSensor: self.watchOwnsSensor,
                    notificationsAuthorized: self.notificationsAuthorized, now: Date()
                ) else {
                    self.center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    self.center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    return
                }
                if let error {
                    self.onStatusChange?("Watch-alarm kunne ikke oprettes: \((error as NSError).domain) \((error as NSError).code)")
                    return
                }
                self.state.recordAutomaticThrottle(rule.kind, readingID: reading.id,
                    until: now.addingTimeInterval(Double(ConstantsAlerts.defaultDelayBetweenAlertsOfSameKindInMinutes) * 60))
                LibreWatchAlarmStore.save(self.state)
                #if canImport(WatchKit)
                if rule.vibrate && !rule.soundEnabled { WKInterfaceDevice.current().play(.notification) }
                #endif
                self.onSnooze?()
            }
        }
    }

    private func reconcileScheduledMissedAlarm() {
        let requestedID = state.scheduledMissedID
        let requestedSessionID = state.sessionID
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            self.center.getDeliveredNotifications { [weak self] delivered in
                DispatchQueue.main.async {
                    guard let self, self.notificationsAuthorized,
                          self.state.scheduledMissedID == requestedID,
                          self.state.sessionID == requestedSessionID
                    else { return }
                    let knownIDs = Set(pending.map(\.identifier) + delivered.map { $0.request.identifier })
                    if let identifier = self.state.scheduledMissedID, !knownIDs.contains(identifier),
                       self.state.shouldRestoreMissingMissedNotification(at: Date()) {
                        self.state.scheduledMissedID = nil
                        LibreWatchAlarmStore.save(self.state)
                    }
                    self.scheduleMissedIfNeeded()
                }
            }
        }
    }

    private func scheduleMissedIfNeeded(at now: Date = Date()) {
        guard notificationsAuthorized, let settings,
              let missed = state.nextMissedAlarm(settings: settings, delegation: delegation,
                watchOwnsSensor: watchOwnsSensor, now: now),
              let baseline = state.missedReadingBaseline
        else { return }
        let snoozedUntil = state.snoozedUntil(.missed, settings: settings).timeIntervalSince1970
        let snoozeAllUntil = settings.snoozeAllUntil?.timeIntervalSince1970 ?? 0
        let identifier = "libreWatchAlarm.missed.\(settings.sessionID.uuidString).\(baseline.timeIntervalSince1970).\(settings.revision).\(snoozedUntil).\(snoozeAllUntil)"
        guard state.scheduledMissedID != identifier else { return }
        if let previous = state.scheduledMissedID { center.removePendingNotificationRequests(withIdentifiers: [previous]) }
        let content = content(for: missed.rule)
        content.userInfo["libreWatchAlarmBaseline"] = baseline.timeIntervalSince1970
        if let readingAt = state.lastReadingAt, readingAt >= baseline {
            content.body = "Ingen ny direkte Libre-måling siden \(readingAt.formatted(date: .omitted, time: .shortened))."
        } else {
            content.body = "Ingen direkte Libre-måling efter overtagelsen kl. \(baseline.formatted(date: .omitted, time: .shortened))."
        }
        let request = UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, missed.date.timeIntervalSince(now)), repeats: false))
        state.scheduledMissedID = identifier
        state.scheduledMissedAt = missed.date
        state.scheduledMissedConfirmed = false
        LibreWatchAlarmStore.save(state)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.watchOwnsSensor || self.state.scheduledMissedID != identifier {
                    self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
                } else if let error {
                    self.state.scheduledMissedID = nil
                    LibreWatchAlarmStore.save(self.state)
                    self.onStatusChange?("Watch-alarm kunne ikke planlægges: \((error as NSError).domain) \((error as NSError).code)")
                } else {
                    self.state.scheduledMissedConfirmed = true
                    LibreWatchAlarmStore.save(self.state)
                }
            }
        }
    }

    private func content(for rule: LibreWatchAlarmRule) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = rule.title
        content.threadIdentifier = "libreWatchLocalAlarms"
        content.userInfo = ["libreWatchAlarmKind": rule.kind.rawValue, "libreWatchAlarmSession": settings?.sessionID.uuidString ?? ""]
        content.userInfo["libreWatchAlarmReading"] = state.lastReadingID?.uuidString
        if rule.allowsSnooze { content.categoryIdentifier = category }
        // watchOS controls mute/haptics; no critical-alert entitlement or override is claimed.
        if rule.soundEnabled { content.sound = .default }
        return content
    }

    private func identifier(for kind: LibreWatchAlarmKind) -> String { "libreWatchAlarm.\(kind.rawValue)" }

    private func cancelScheduledAlarms() {
        var identifiers = LibreWatchAlarmKind.allCases.map(identifier(for:))
        if let missed = state.scheduledMissedID { identifiers.append(missed) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        state.scheduledMissedID = nil
        state.scheduledMissedAt = nil
        state.scheduledMissedConfirmed = nil
        LibreWatchAlarmStore.save(state)
    }

    private func publishStatus() {
        guard let settings else { onStatusChange?("Watch-alarmer: venter på iPhone-indstillinger"); return }
        if !settings.rules.contains(where: \.enabled) {
            onStatusChange?("Watch-alarmer er slået fra i dine indstillinger")
        } else if let until = settings.snoozeAllUntil, until > Date() {
            onStatusChange?("Snooze All indtil \(until.formatted(date: .omitted, time: .shortened))")
        } else if !notificationsAuthorized {
            onStatusChange?("Watch-notifikationer er ikke tilladt. iPhone skal bekræfte alarmansvaret.")
        } else if watchOwnsSensor, delegation?.matches(settings) == true {
            onStatusChange?(configuration.pendingSettings == nil
                ? "Lokale Watch-alarmer er aktive; watchOS styrer lyd og baggrundslevering"
                : "Watch-alarmer bruger bekræftede indstillinger; afventer opdatering fra iPhone")
        } else {
            onStatusChange?("Alarmansvaret er hos iPhone")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        guard let notificationSessionID = info["libreWatchAlarmSession"] as? String else {
            completionHandler([.banner, .sound])
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let rawKind = info["libreWatchAlarmKind"] as? Int,
                  let kind = LibreWatchAlarmKind(rawValue: rawKind),
                  self.state.notificationMayBePresented(kind: kind, notificationSessionID: notificationSessionID,
                    notificationReadingID: (info["libreWatchAlarmReading"] as? String).flatMap(UUID.init(uuidString:)),
                    settings: self.settings, delegation: self.delegation,
                    watchOwnsSensor: self.watchOwnsSensor, notificationsAuthorized: self.notificationsAuthorized,
                    at: Date(), notificationMissedBaseline: (info["libreWatchAlarmBaseline"] as? Double)
                        .map { Date(timeIntervalSince1970: $0) })
            else { completionHandler([]); return }
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            defer { completionHandler() }
            guard let self, response.actionIdentifier == self.snoozeAction, let settings = self.settings,
                  response.notification.request.content.userInfo["libreWatchAlarmSession"] as? String == settings.sessionID.uuidString,
                  let rawKind = response.notification.request.content.userInfo["libreWatchAlarmKind"] as? Int,
                  let kind = LibreWatchAlarmKind(rawValue: rawKind),
                  let rule = settings.rule(for: kind, at: Date()), rule.allowsSnooze
            else { return }
            self.state.snooze(kind, until: Date().addingTimeInterval(Double(rule.snoozeMinutes) * 60))
            LibreWatchAlarmStore.save(self.state)
            self.center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
            self.scheduleMissedIfNeeded()
            self.onSnooze?()
        }
    }
}
