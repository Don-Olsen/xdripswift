import Foundation
import WatchConnectivity

extension Notification.Name {
    static let watchDeliveryEvidenceChanged = Notification.Name("watchDeliveryEvidenceChanged")
}

/// Explicit support action, separate from status polling and from clinical delivery queues.
/// The reply confirms only creation of an OS file-transfer request. Arrival is recorded later.
final class WatchDeliveryEvidenceTransfer {
    static let shared = WatchDeliveryEvidenceTransfer()
    static let requestKey = "watchDeliveryEvidenceRequestV1"
    static let fileKey = "watchDeliveryEvidenceFileV1"
    static let requestIDKey = "watchDeliveryEvidenceRequestID"
    static let timeout: TimeInterval = 8
    private let directory: URL
    private var requestID: UUID?
    private var timeoutWork: DispatchWorkItem?
    private(set) var status = "No local Watch evidence has been requested."
    private let defaults: UserDefaults
    private let evidenceStore: WatchDeliveryEvidenceStore
    private var receivedURL: URL { directory.appendingPathComponent("received-watch-evidence-v1.json") }

    init(directory: URL = WatchDeliveryEvidenceStore.defaultDirectory, defaults: UserDefaults = .standard,
         store: WatchDeliveryEvidenceStore = .shared) {
        self.directory = directory
        self.defaults = defaults
        evidenceStore = store
        status = defaults.string(forKey: "watchEvidenceTransferStatus") ?? status
    }

    /// Called only by the manual support UI. One request, finite timeout, no compatibility loop.
    func requestFromWatch(session: WCSession = .default) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requestID == nil else { return }
        guard session.activationState == .activated, session.isReachable else {
            updateStatus("Fresh Watch evidence unavailable: Watch transport is not reachable. Any previous snapshot remains dated; open the Watch app and request again when connected.")
            return
        }
        let id = UUID()
        requestID = id
        updateStatus("Requesting the local Watch journal…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == id else { return }
            self.requestID = nil
            self.updateStatus("Watch journal request timed out. No fresh Watch snapshot is confirmed; any previous snapshot is retained.")
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)
        session.sendMessage([Self.requestKey: 1, Self.requestIDKey: id.uuidString], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.timeoutWork?.cancel(); self.requestID = nil
                if self.defaults.string(forKey: "watchEvidenceReceivedRequestID") == id.uuidString { return }
                if reply[Self.requestIDKey] as? String == id.uuidString, reply[Self.fileKey] as? Bool == true {
                    self.updateStatus("Watch journal transfer requested. Waiting for the file; it is not yet included in this phone's export.")
                } else {
                    self.updateStatus("The Watch did not provide a local journal. It may require the matching app version; no fallback request was started.")
                }
            }
        }, errorHandler: { [weak self] error in
            let failure = WatchDeliveryEvidenceStore.errorClass(error)
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.timeoutWork?.cancel(); self.requestID = nil
                self.updateStatus("Watch journal request failed (\(failure)). Fresh local Watch evidence is missing.")
            }
        })
    }

    /// Watch delegate calls this before normal request routing. No session/calibration payload
    /// is produced. An old phone/Watch gets one explicit unsupported result, never a retry loop.
    @discardableResult
    func handleRequest(_ message: [String: Any], session: WCSession,
                       reply: (([String: Any]) -> Void)?, store: WatchDeliveryEvidenceStore = .shared) -> Bool {
        guard message[Self.requestKey] != nil else { return false }
        guard message[Self.requestKey] as? Int == 1,
              let id = (message[Self.requestIDKey] as? String).flatMap(UUID.init(uuidString:)),
              session.activationState == .activated,
              session.outstandingFileTransfers.filter({ $0.file.metadata?[Self.fileKey] != nil }).count < 2 else {
            reply?([Self.fileKey: false]); return true
        }
        do {
            // File remains on disk until WCSession's didFinish callback. transferFile is the
            // supported bounded handoff for a journal larger than an interactive message.
            let file = try store.exportFile(requestID: id)
            session.transferFile(file, metadata: [Self.fileKey: 1, Self.requestIDKey: id.uuidString])
            store.recordTransport(stream: .diagnostic, action: "supportFileSubmitted")
            reply?([Self.fileKey: true, Self.requestIDKey: id.uuidString])
        } catch {
            store.recordTransport(stream: .diagnostic, action: "supportFileFailed", outcome: WatchDeliveryEvidenceStore.errorClass(error))
            reply?([Self.fileKey: false, Self.requestIDKey: id.uuidString])
        }
        return true
    }

    /// Must run synchronously in didReceive(file:) because WCSession removes its temporary file
    /// when the delegate returns. Only after validation and atomic copy is arrival announced.
    @discardableResult
    func receive(fileURL: URL, metadata: [String: Any]?) -> Bool {
        guard metadata?[Self.fileKey] != nil else { return false }
        do {
            guard metadata?[Self.fileKey] as? Int == 1 else { throw ImportError.invalidFile }
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 8 * 1024 * 1024 else { throw ImportError.invalidFile }
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(WatchDeliveryEvidenceSnapshot.self, from: data)
            guard snapshot.version == 1, snapshot.origin.device == "watch",
                  snapshot.events.count <= WatchDeliveryEvidenceStore.defaultMaximumEvents else { throw ImportError.invalidFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A delayed older transfer must not replace a newer snapshot already imported.
            if let existingData = try? Data(contentsOf: receivedURL),
               let existing = try? JSONDecoder().decode(WatchDeliveryEvidenceSnapshot.self, from: existingData),
               existing.origin.installation == snapshot.origin.installation,
               existing.exportedAt > snapshot.exportedAt { return true }
            try data.write(to: receivedURL, options: .atomic)
            defaults.set(metadata?[Self.requestIDKey] as? String, forKey: "watchEvidenceReceivedRequestID")
            evidenceStore.recordTransport(stream: .diagnostic, action: "supportFileReceived")
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus("Local Watch journal received. Snapshot created \(ISO8601DateFormatter().string(from: snapshot.exportedAt)); \(snapshot.events.count) retained events, \(snapshot.rotatedEvents) rotated. Share/export now includes this snapshot.")
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatus("Watch journal file could not be stored or validated. Fresh local Watch evidence is missing.")
            }
        }
        return true
    }

    /// Only our own completed support file is deleted; clinical files/queues are untouched.
    func finished(_ transfer: WCSessionFileTransfer, error: Error?) {
        guard transfer.file.metadata?[Self.fileKey] != nil else { return }
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: .diagnostic,
            action: error == nil ? "supportFileFinished" : "supportFileFailed",
            outcome: error.map(WatchDeliveryEvidenceStore.errorClass))
        let url = transfer.file.fileURL.standardizedFileURL
        let base = WatchDeliveryEvidenceStore.defaultDirectory.standardizedFileURL
        if url.deletingLastPathComponent() == base, url.lastPathComponent.hasPrefix("watch-evidence-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func supportData(store: WatchDeliveryEvidenceStore = .shared) -> Data {
        struct Export: Codable {
            let version = 1
            let generatedAt: Date
            let watchTransferStatus: String
            let phone: WatchDeliveryEvidenceSnapshot
            let watch: WatchDeliveryEvidenceSnapshot?
            let missingMaterial: String
        }
        let watch = (try? Data(contentsOf: receivedURL)).flatMap { try? JSONDecoder().decode(WatchDeliveryEvidenceSnapshot.self, from: $0) }
        let export = Export(generatedAt: Date(), watchTransferStatus: status, phone: store.snapshot(), watch: watch,
            missingMaterial: watch == nil ? "No local Watch snapshot available. Phone events do not replace offline Watch evidence." : "Watch coverage ends at the retained snapshot's exportedAt. Later Watch events and rotated/unreadable/failed journal writes are not included. Clock offset between devices is unknown.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(export)) ?? Data("{\"error\":\"evidenceExportEncodingFailed\"}".utf8)
    }

    func supportText() -> String {
        "\n\nLOCAL WATCH DELIVERY EVIDENCE\n" + (String(data: supportData(), encoding: .utf8) ?? "Evidence unavailable")
    }

    private func updateStatus(_ text: String) {
        status = text
        defaults.set(text, forKey: "watchEvidenceTransferStatus")
        NotificationCenter.default.post(name: .watchDeliveryEvidenceChanged, object: self)
    }

    private enum ImportError: Error { case invalidFile }
}
