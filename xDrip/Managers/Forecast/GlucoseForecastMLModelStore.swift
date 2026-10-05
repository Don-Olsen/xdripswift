// Device-local model packages. A candidate becomes active only after every model
// has been compiled, loaded again, and checked against the exact feature schema.
import Foundation
import CoreML
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CreateML)
import CreateML
#endif

struct GlucoseForecastMLStatusSummary: Sendable {
    let isTraining: Bool
    let progress: GlucoseForecastMLTrainingProgress?
    let activeModelID: String?
    let trainedAt: Date?
    let lastAttempt: Date?
    let lastOutcome: String?
    let lastIssue: GlucoseForecastMLTrainingIssue?
    let lastSelfCheck: GlucoseForecastMLSelfCheck?
}

/// Counts only completed work. Create ML may spend very different amounts of
/// time on each fit, so the UI reports the completed count rather than an ETA.
enum GlucoseForecastMLTrainingProgress: Equatable, Sendable {
    case trainingModels(completed: Int, total: Int)
    case calibrating
    case selfChecking
    case installing
}

enum GlucoseForecastMLModelCompatibility {
    enum InvalidReason: Equatable {
        case packageUnavailable
        case generationChanged
        case parametersChanged
        case sourceChanged
        case malformedSignature
        case transitionUnverified
        case sourceSetupIncomplete
        case prospectiveWorse
        case evidenceUnreadable
    }

    enum Assessment: Equatable {
        case exact
        case transitionCompatible(TreatmentSourceCutover)
        case invalid(InvalidReason)
    }

    /// Parse the complete historical signature, rather than replacing substrings
    /// in an opaque string. This accepts only the two known serialized layouts:
    /// before the cutoff field existed, and the layout with an explicit cutoff.
    private struct SourceSignature {
        struct Import: Equatable {
            let enabled: Bool
            let bundleID: String
        }
        let unchangedFields: [String]
        let imports: [Import]
        let cutoff: String?

        init?(_ raw: String) {
            let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 || fields.count == 8,
                  fields[0...4].allSatisfy({ !$0.isEmpty }), fields[2] == "120" else { return nil }
            var parsed = [Import]()
            for field in fields[5...6] {
                let parts = field.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let enabled = Bool(String(parts[0])) else { return nil }
                parsed.append(Import(enabled: enabled, bundleID: String(parts[1])))
            }
            if fields.count == 8 {
                let parts = fields[7].split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 4, parts[0] == "cutover",
                      let seconds = Double(parts[1]), seconds.isFinite,
                      seconds >= 0 else { return nil }
            }
            unchangedFields = Array(fields[0...4])
            imports = parsed
            cutoff = fields.count == 8 ? fields[7] : nil
        }
    }

    static func assess(_ metadata: GlucoseForecastMLModelMetadata,
                       current: GlucoseForecastMLContext,
                       currentPolicy: DataFlowPolicy,
                       cutover: TreatmentSourceCutover?, restoreRequiresSetup: Bool = false)
        -> Assessment {
        guard isUsable(metadata), metadata.context.engineVersion == current.engineVersion,
              metadata.context.featureVersion == current.featureVersion else {
            return .invalid(.generationChanged)
        }
        guard !restoreRequiresSetup else { return .invalid(.sourceSetupIncomplete) }
        guard metadata.context.sensitivityMgdlPerUnit == current.sensitivityMgdlPerUnit,
              metadata.context.carbohydrateRatioGramsPerUnit == current.carbohydrateRatioGramsPerUnit,
              metadata.context.insulinDurationMinutes == current.insulinDurationMinutes,
              metadata.context.insulinPeakMinutes == current.insulinPeakMinutes,
              metadata.context.carbohydrateDurationMinutes == current.carbohydrateDurationMinutes else {
            return .invalid(.parametersChanged)
        }
        if metadata.context == current { return .exact }
        guard let old = SourceSignature(metadata.context.sourceSignature),
              let new = SourceSignature(current.sourceSignature) else {
            return .invalid(.malformedSignature)
        }
        guard let cutover, cutover.cutoff > metadata.trainedAt else {
            return .invalid(.sourceChanged)
        }
        guard old.unchangedFields.dropFirst() == new.unchangedFields.dropFirst(),
              currentPolicy.therapyDataSource == .none,
              new.unchangedFields[0] == String(describing: currentPolicy),
              TherapyDataSourceType.allCases.contains(where: { selection in
                  let previous = DataFlowPolicy(
                      isMaster: currentPolicy.isMaster,
                      followerDataSource: currentPolicy.followerDataSource,
                      therapyDataSourceSelection: selection,
                      nightscoutEnabled: currentPolicy.nightscoutEnabled,
                      masterUploadsGlucoseToNightscout: currentPolicy.masterUploadsGlucoseToNightscout,
                      followerUploadsGlucoseToNightscout: currentPolicy.followerUploadsGlucoseToNightscout,
                      nightscoutFollowType: currentPolicy.nightscoutFollowType)
                  return previous.therapyDataSource == .none
                      && !previous.importsTreatmentsFromNightscout
                      && !previous.importsTherapyFromCareLink
                      && old.unchangedFields[0] == String(describing: previous)
              }),
              old.cutoff == nil || old.cutoff == "cutover:0.0::",
              new.cutoff == "cutover:\(cutover.cutoff.timeIntervalSince1970):"
                    + "\(cutover.insulinSourceBundleID):\(cutover.carbohydrateSourceBundleID)",
              old.imports == [
                  .init(enabled: true, bundleID: cutover.insulinSourceBundleID),
                  .init(enabled: true, bundleID: cutover.carbohydrateSourceBundleID)
              ],
              new.imports == [
                  .init(enabled: false, bundleID: cutover.insulinSourceBundleID),
                  .init(enabled: false, bundleID: cutover.carbohydrateSourceBundleID)
              ] else { return .invalid(.transitionUnverified) }
        return .transitionCompatible(cutover)
    }

    static func matchesGeneration(_ metadata: GlucoseForecastMLModelMetadata) -> Bool {
        metadata.schemaVersion == GlucoseForecastMLModelMetadata.schemaVersion
            && metadata.featureNames == GlucoseForecastMLFeatures.featureNames
            && metadata.context.engineVersion == GlucoseForecastEngine.engineVersion
            && metadata.context.featureVersion == GlucoseForecastMLFeatures.featureVersion
    }

    static func isUsable(_ metadata: GlucoseForecastMLModelMetadata) -> Bool {
        matchesGeneration(metadata)
            && GlucoseForecastMLStoragePolicy.isGeneratedUUID(metadata.modelID)
            && metadata.selfCheck.promoted
    }
}

/// Loaded once on a utility task; runtime prediction only uses these cached models.
final class GlucoseForecastMLLoadedBundle: @unchecked Sendable {
    let metadata: GlucoseForecastMLModelMetadata
    private let models: [String: MLModel]

    init(metadata: GlucoseForecastMLModelMetadata, models: [String: MLModel]) {
        self.metadata = metadata
        self.models = models
    }

    func prediction(kind: String, horizon: Int, row: GlucoseForecastMLFeatureRow) -> Double? {
        guard let model = models["\(kind)_\(horizon)"] else { return nil }
        return GlucoseForecastMLScoring.predict(model, row: row)
    }
}

enum GlucoseForecastMLScoring {
    static func predict(_ model: MLModel, row: GlucoseForecastMLFeatureRow) -> Double? {
        let names = GlucoseForecastMLFeatures.featureNames
        guard names.count == 16, row.values.count == names.count,
              row.values.allSatisfy(\.isFinite) else { return nil }
        do {
            let values = Dictionary(uniqueKeysWithValues: zip(names, row.values))
            let input = try MLDictionaryFeatureProvider(dictionary: values)
            let output = try model.prediction(from: input)
            let outputName = model.modelDescription.predictedFeatureName ?? "target"
            guard let value = output.featureValue(for: outputName)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        } catch { return nil }
    }
}

/// Create ML writes checkpoints directly into its session directory. Secure the
/// directory before constructing a training job, so even an interrupted run is
/// protected and excluded from the device backup.
enum GlucoseForecastMLStoragePolicy {
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    static func isGeneratedUUID(_ name: String) -> Bool {
        guard let id = UUID(uuidString: name) else { return false }
        return id.uuidString.lowercased() == name
    }

    static func secureDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        guard isRealDirectory(url) else { throw GlucoseForecastMLTrainingFailure.packageInvalid }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: url.path)
        #endif
    }
}

final class GlucoseForecastMLModelStore {
    private struct ActivePointer: Codable { let modelID: String }
    private struct SavedReview: Codable {
        let modelSchemaVersion: Int
        let engineVersion: String
        let featureVersion: String
        let modelID: String?
        let report: GlucoseForecastMLSelfCheck

        var matchesCurrentGeneration: Bool {
            modelSchemaVersion == GlucoseForecastMLModelMetadata.schemaVersion
                && engineVersion == GlucoseForecastEngine.engineVersion
                && featureVersion == GlucoseForecastMLFeatures.featureVersion
        }
    }
    let directory: URL
    private let fileManager = FileManager.default
    private let sessionLock = NSLock()
    private var activeTrainingSession: URL?
    private let stagingLock = NSLock()
    private var stagingInUse: URL?

    init(directory: URL) { self.directory = directory }

    private var modelsDirectory: URL { directory.appendingPathComponent("models", isDirectory: true) }
    private var pointerURL: URL { directory.appendingPathComponent("active.json") }
    private var reviewURL: URL { directory.appendingPathComponent("latest-review.json") }
    private var trainingSessionsDirectory: URL {
        directory.appendingPathComponent("training-sessions", isDirectory: true)
    }

    func loadActive() async -> GlucoseForecastMLLoadedBundle? {
        // The manager finishes loading before it permits a new training run.
        // A crash leaves checkpoints here; a future launch removes only UUID
        // session directories, never model packages or unrelated files.
        try? cleanupStaleTrainingSessions()
        guard let data = try? Data(contentsOf: pointerURL),
              let pointer = try? JSONDecoder().decode(ActivePointer.self, from: data),
              UUID(uuidString: pointer.modelID) != nil else { return nil }
        guard let bundle = try? await loadBundle(
            at: modelsDirectory.appendingPathComponent(pointer.modelID, isDirectory: true)),
              bundle.metadata.modelID == pointer.modelID else {
            return nil
        }
        try? await pruneObsoletePackages(activeModelID: pointer.modelID)
        try? cleanupAbandonedStaging(activeModelID: pointer.modelID)
        return bundle
    }

    func prepareTrainingSession() throws -> URL {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard activeTrainingSession == nil else {
            throw GlucoseForecastMLTrainingFailure.packageInvalid
        }
        try prepareDirectory()
        try GlucoseForecastMLStoragePolicy.secureDirectory(trainingSessionsDirectory,
                                                          fileManager: fileManager)
        try removeStaleTrainingSessions(excluding: nil)
        let session = trainingSessionsDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try GlucoseForecastMLStoragePolicy.secureDirectory(session, fileManager: fileManager)
        activeTrainingSession = session
        return session
    }

    func finishTrainingSession(_ session: URL) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard activeTrainingSession == session else { return }
        try? fileManager.removeItem(at: session)
        activeTrainingSession = nil
    }

    func cleanupStaleTrainingSessions() throws {
        sessionLock.lock(); defer { sessionLock.unlock() }
        try prepareDirectory()
        try GlucoseForecastMLStoragePolicy.secureDirectory(trainingSessionsDirectory,
                                                          fileManager: fileManager)
        try removeStaleTrainingSessions(excluding: activeTrainingSession)
    }

    private func removeStaleTrainingSessions(excluding active: URL?) throws {
        guard GlucoseForecastMLStoragePolicy.isRealDirectory(trainingSessionsDirectory) else {
            throw GlucoseForecastMLTrainingFailure.packageInvalid
        }
        let contents = try fileManager.contentsOfDirectory(at: trainingSessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for url in contents {
            guard url != active,
                  GlucoseForecastMLStoragePolicy.isGeneratedUUID(url.lastPathComponent),
                  GlucoseForecastMLStoragePolicy.isRealDirectory(url) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    func saveReview(_ metadata: GlucoseForecastMLModelMetadata,
                    rows: [GlucoseForecastMLReviewRow] = []) throws {
        guard GlucoseForecastMLModelCompatibility.matchesGeneration(metadata) else {
            throw GlucoseForecastMLTrainingFailure.packageInvalid
        }
        try prepareDirectory()
        let csvURL = reviewCSVURL(modelID: metadata.modelID)
        let stagedReview = directory.appendingPathComponent(
            "latest-review-\(UUID().uuidString.lowercased()).tmp")
        var createdCSV = false
        let review = SavedReview(
            modelSchemaVersion: metadata.schemaVersion,
            engineVersion: metadata.context.engineVersion,
            featureVersion: metadata.context.featureVersion,
            modelID: rows.isEmpty ? nil : metadata.modelID,
            report: metadata.selfCheck)
        do {
            if !rows.isEmpty {
                guard GlucoseForecastMLStoragePolicy.isGeneratedUUID(metadata.modelID),
                      let csv = GlucoseForecastMLReviewCSV.data(rows,
                                                                context: metadata.context) else {
                    throw GlucoseForecastMLTrainingFailure.packageInvalid
                }
                if fileManager.fileExists(atPath: csvURL.path) {
                    // Never overwrite evidence for a previously saved review ID.
                    guard try Data(contentsOf: csvURL) == csv else {
                        throw GlucoseForecastMLTrainingFailure.packageInvalid
                    }
                } else {
                    try csv.write(to: csvURL, options: .atomic)
                    createdCSV = true
                    try protect(csvURL)
                }
            }
            try JSONEncoder().encode(review).write(to: stagedReview, options: .atomic)
            try protect(stagedReview)
            if fileManager.fileExists(atPath: reviewURL.path) {
                let targetType = try fileManager.attributesOfItem(
                    atPath: reviewURL.path)[.type] as? FileAttributeType
                guard targetType == .typeRegular,
                      let values = try? reviewURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    throw GlucoseForecastMLTrainingFailure.packageInvalid
                }
                _ = try fileManager.replaceItemAt(reviewURL, withItemAt: stagedReview,
                    backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: stagedReview, to: reviewURL)
            }
        } catch {
            // Any failed protection or review commit leaves the previous review
            // intact and removes the new sensitive CSV rather than orphaning it.
            if createdCSV { try? fileManager.removeItem(at: csvURL) }
            try? fileManager.removeItem(at: stagedReview)
            throw error
        }
        if !rows.isEmpty { pruneOlderReviewCSVs(keeping: metadata.modelID) }
    }

    func loadReview() -> GlucoseForecastMLSelfCheck? {
        guard let data = try? Data(contentsOf: reviewURL) else { return nil }
        guard let saved = try? JSONDecoder().decode(SavedReview.self, from: data),
              saved.matchesCurrentGeneration else { return nil }
        return saved.report
    }

    /// A review export is available only for the matching current-generation
    /// self-check. A previous build's bare review cannot expose a stale CSV.
    func reviewCSVURL() -> URL? {
        guard let data = try? Data(contentsOf: reviewURL),
              let saved = try? JSONDecoder().decode(SavedReview.self, from: data),
              saved.matchesCurrentGeneration,
              let modelID = saved.modelID,
              GlucoseForecastMLStoragePolicy.isGeneratedUUID(modelID) else { return nil }
        let url = reviewCSVURL(modelID: modelID)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    private func reviewCSVURL(modelID: String) -> URL {
        directory.appendingPathComponent("self-check-\(modelID).csv")
    }

    private func pruneOlderReviewCSVs(keeping modelID: String) {
        guard let children = try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("self-check-"), name.hasSuffix(".csv"),
                  name != "self-check-\(modelID).csv" else { continue }
            let candidateID = String(name.dropFirst("self-check-".count).dropLast(".csv".count))
            guard GlucoseForecastMLStoragePolicy.isGeneratedUUID(candidateID),
                  let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? fileManager.removeItem(at: child)
        }
    }

    #if canImport(CreateML)
    func install(_ candidate: GlucoseForecastMLTrainedCandidate) async throws -> GlucoseForecastMLLoadedBundle {
        let metadata = candidate.metadata
        guard GlucoseForecastMLModelCompatibility.isUsable(metadata),
              candidate.models.count == 6 else { throw GlucoseForecastMLTrainingFailure.packageInvalid }
        try prepareDirectory()
        let staging = modelsDirectory.appendingPathComponent(metadata.modelID + ".staging", isDirectory: true)
        let final = modelsDirectory.appendingPathComponent(metadata.modelID, isDirectory: true)
        let reserved = stagingLock.withLock { () -> Bool in
            guard stagingInUse == nil else { return false }
            stagingInUse = staging
            return true
        }
        guard reserved else { throw GlucoseForecastMLTrainingFailure.packageInvalid }
        defer { stagingLock.withLock { stagingInUse = nil } }
        guard !fileManager.fileExists(atPath: staging.path),
              !fileManager.fileExists(atPath: final.path) else {
            throw GlucoseForecastMLTrainingFailure.packageInvalid
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try protect(staging)
        do {
            // One write and compile at a time; the active package is untouched.
            for horizon in GlucoseForecastMLChronology.horizons {
                for kind in ["correction", "error"] {
                    try Task.checkCancellation()
                    let key = "\(kind)_\(horizon)"
                    guard let model = candidate.models[key] else {
                        throw GlucoseForecastMLTrainingFailure.packageInvalid
                    }
                    let source = staging.appendingPathComponent(key + ".mlmodel")
                    try model.write(to: source)
                    let compiled = try await MLModel.compileModel(at: source)
                    let destination = staging.appendingPathComponent(key + ".mlmodelc", isDirectory: true)
                    try fileManager.moveItem(at: compiled, to: destination)
                    try fileManager.removeItem(at: source)
                    try protect(destination)
                }
            }
            let manifest = staging.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(metadata).write(to: manifest, options: .atomic)
            try protect(manifest)
            // Re-read the disk package before the single-pointer activation.
            _ = try await loadBundle(at: staging)
            try Task.checkCancellation()
            try fileManager.moveItem(at: staging, to: final)
            let verifiedFinal = try await loadBundle(at: final)
            try Task.checkCancellation()
            // Data.write(.atomic) uses a same-directory replacement; an interrupted
            // write leaves the previous pointer intact.
            let previousActiveModelID = currentActiveModelID()
            try JSONEncoder().encode(ActivePointer(modelID: metadata.modelID))
                .write(to: pointerURL, options: .atomic)
            try? protect(pointerURL)
            // Retention is best effort and runs only after the pointer names a
            // fully reloaded package. Keep the exact formerly active model:
            // in-flight inference may still hold it while the pointer changes.
            try? await pruneObsoletePackages(activeModelID: metadata.modelID,
                                             protectedPreviousModelID: previousActiveModelID)
            return verifiedFinal
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }
    #endif

    private func loadBundle(at url: URL) async throws -> GlucoseForecastMLLoadedBundle {
        let manifest = url.appendingPathComponent("metadata.json")
        let metadata = try JSONDecoder().decode(GlucoseForecastMLModelMetadata.self,
                                                from: Data(contentsOf: manifest))
        guard GlucoseForecastMLModelCompatibility.isUsable(metadata) else {
            throw GlucoseForecastMLTrainingFailure.packageInvalid
        }
        var models = [String: MLModel]()
        for horizon in GlucoseForecastMLChronology.horizons {
            for kind in ["correction", "error"] {
                let key = "\(kind)_\(horizon)"
                let modelURL = url.appendingPathComponent(key + ".mlmodelc", isDirectory: true)
                let model = try await MLModel.load(contentsOf: modelURL)
                let description = model.modelDescription
                guard Set(description.inputDescriptionsByName.keys) == Set(metadata.featureNames),
                      description.inputDescriptionsByName.values.allSatisfy({ $0.type == .double }),
                      let outputName = description.predictedFeatureName,
                      description.outputDescriptionsByName[outputName]?.type == .double else {
                    throw GlucoseForecastMLTrainingFailure.packageInvalid
                }
                models[key] = model
            }
        }
        guard models.count == 6 else { throw GlucoseForecastMLTrainingFailure.packageInvalid }
        return GlucoseForecastMLLoadedBundle(metadata: metadata, models: models)
    }

    private func prepareDirectory() throws {
        try GlucoseForecastMLStoragePolicy.secureDirectory(directory, fileManager: fileManager)
        try GlucoseForecastMLStoragePolicy.secureDirectory(modelsDirectory, fileManager: fileManager)
        try protect(directory)
        try protect(modelsDirectory)
    }

    private func currentActiveModelID() -> String? {
        guard let data = try? Data(contentsOf: pointerURL),
              let pointer = try? JSONDecoder().decode(ActivePointer.self, from: data),
              GlucoseForecastMLStoragePolicy.isGeneratedUUID(pointer.modelID) else { return nil }
        return pointer.modelID
    }

    private func pruneObsoletePackages(activeModelID: String,
                                       protectedPreviousModelID: String? = nil) async throws {
        try await pruneModelDirectories(activeModelID: activeModelID,
                                        protectedPreviousModelID: protectedPreviousModelID) { [self] url in
            guard let bundle = try? await loadBundle(at: url),
                  bundle.metadata.modelID == url.lastPathComponent else { return nil }
            return bundle.metadata.trainedAt
        }
    }

    func cleanupAbandonedStaging(activeModelID: String) throws {
        guard currentActiveModelID() == activeModelID,
              GlucoseForecastMLStoragePolicy.isRealDirectory(modelsDirectory) else { return }
        let children = try fileManager.contentsOfDirectory(at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for child in children {
            let name = child.lastPathComponent
            guard name.hasSuffix(".staging"),
                  GlucoseForecastMLStoragePolicy.isGeneratedUUID(
                    String(name.dropLast(".staging".count))),
                  GlucoseForecastMLStoragePolicy.isRealDirectory(child),
                  stagingLock.withLock({ stagingInUse != child }) else { continue }
            guard currentActiveModelID() == activeModelID else { return }
            try fileManager.removeItem(at: child)
        }
    }

    /// Only loaded and validated UUID packages may enter this set. The newest
    /// previous package remains available for rollback; malformed or unknown
    /// directories remain untouched. The verifier is injectable for filesystem
    /// tests without manufacturing six compiled Core ML models.
    func pruneModelDirectories(activeModelID: String,
                               protectedPreviousModelID: String? = nil,
                               verifiedTrainingDate: (URL) async -> Date?) async throws {
        guard currentActiveModelID() == activeModelID,
              GlucoseForecastMLStoragePolicy.isRealDirectory(directory),
              GlucoseForecastMLStoragePolicy.isRealDirectory(modelsDirectory) else { return }
        let children = try fileManager.contentsOfDirectory(at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var verified = [(url: URL, date: Date)]()
        for child in children where child.lastPathComponent != activeModelID {
            guard GlucoseForecastMLStoragePolicy.isGeneratedUUID(child.lastPathComponent),
                  GlucoseForecastMLStoragePolicy.isRealDirectory(child),
                  let date = await verifiedTrainingDate(child) else { continue }
            verified.append((child, date))
        }
        let previous: URL?
        if let protectedPreviousModelID {
            // An interrupted install may have left a newer verified orphan.
            // It must not displace the previous active model during live use.
            previous = verified.first {
                $0.url.lastPathComponent == protectedPreviousModelID
            }?.url
        } else {
            previous = verified.max { lhs, rhs in
                lhs.date == rhs.date
                    ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
                    : lhs.date < rhs.date
            }?.url
        }
        for item in verified where item.url != previous {
            // A changed or unreadable pointer stops the entire cleanup.
            guard currentActiveModelID() == activeModelID else { return }
            guard item.url.lastPathComponent != protectedPreviousModelID else { continue }
            guard GlucoseForecastMLStoragePolicy.isRealDirectory(item.url),
                  GlucoseForecastMLStoragePolicy.isGeneratedUUID(item.url.lastPathComponent) else {
                continue
            }
            try fileManager.removeItem(at: item.url)
        }
    }

    private func protect(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: url.path)
        #endif
    }
}

/// Thread-safe process owner. Training runs on one utility Task, while inference
/// reads an already loaded, immutable bundle. No disk or Create ML work occurs in
/// the forecast adapter's calculation path.
/// Prospective, paired evidence for the *specific* pre-cutover package. Predictions
/// are frozen before their target reading exists; neither retrospective replay nor
/// later re-inference is allowed to manufacture a comparison. File IO is serialized
/// off the forecast worker and an interrupted atomic write preserves the last state.
final class GlucoseForecastMLTransitionEvidence: @unchecked Sendable {
    struct Prediction: Codable, Equatable {
        let referenceDate: Date
        let computedAt: Date
        let sensorID: String
        let engine60Mgdl: Double
        let model60Mgdl: Double
        var targetDate: Date { referenceDate.addingTimeInterval(60 * 60) }
    }

    struct Pair: Codable {
        let prediction: Prediction
        let actualDate: Date
        let actualMgdl: Double
    }

    struct Result: Codable, Equatable {
        let usableDays: Int
        let pairCount: Int
        let engineMAE: Double
        let modelMAE: Double
        var modelIsWorse: Bool { modelMAE > engineMAE }
    }

    struct State: Codable {
        static let schemaVersion = 1
        let schemaVersion: Int
        let modelID: String
        let cutoff: Date
        let dayTimeZoneIdentifier: String
        var pending: [Prediction]
        var pairs: [Pair]
        var result: Result?

        init(modelID: String, cutoff: Date, dayTimeZone: TimeZone = .current) {
            schemaVersion = Self.schemaVersion
            self.modelID = modelID
            self.cutoff = cutoff
            dayTimeZoneIdentifier = dayTimeZone.identifier
            pending = []
            pairs = []
            result = nil
        }

        /// Derive a conservative per-day floor from the existing 100-row ML
        /// self-check minimum. Seven days therefore provide at least 105 paired
        /// forecasts; a single isolated Home glance is not a usable day.
        static let minimumPairsPerDay =
            (GlucoseForecastMLChronology.minimumSelfCheckRows + minimumUsableDays - 1)
                / minimumUsableDays
        static let minimumUsableDays = 7

        mutating func add(_ prediction: Prediction) -> Bool {
            guard result == nil, prediction.referenceDate >= cutoff,
                  prediction.referenceDate.timeIntervalSinceReferenceDate.isFinite,
                  prediction.computedAt.timeIntervalSinceReferenceDate.isFinite,
                  prediction.computedAt < prediction.targetDate.addingTimeInterval(-120),
                  !prediction.sensorID.isEmpty,
                  (20...600).contains(prediction.engine60Mgdl),
                  (20...600).contains(prediction.model60Mgdl),
                  !pending.contains(where: { $0.referenceDate == prediction.referenceDate &&
                      $0.sensorID == prediction.sensorID }),
                  !pairs.contains(where: { $0.prediction.referenceDate == prediction.referenceDate &&
                      $0.prediction.sensorID == prediction.sensorID }) else { return false }
            let bucket = Int(prediction.referenceDate.timeIntervalSince1970 / 600)
            guard !pending.contains(where: { Int($0.referenceDate.timeIntervalSince1970 / 600) == bucket }),
                  !pairs.contains(where: { Int($0.prediction.referenceDate.timeIntervalSince1970 / 600) == bucket })
            else { return false }
            pending.append(prediction)
            return true
        }

        mutating func observe(_ readings: [GlucoseForecastSample], at now: Date) -> Bool {
            guard result == nil, now.timeIntervalSinceReferenceDate.isFinite else { return false }
            var changed = false
            var remaining = [Prediction]()
            for prediction in pending {
                let target = prediction.targetDate
                // Wait for the entire ±2-minute matching window. Reading only
                // the first early sample would bias the joined target.
                if now < target.addingTimeInterval(120) {
                    remaining.append(prediction)
                    continue
                }
                let matches = readings.filter {
                    $0.sensorID == prediction.sensorID && $0.date > prediction.computedAt &&
                    abs($0.date.timeIntervalSince(target)) <= 120 &&
                    $0.glucoseMgdl.isFinite && (20...600).contains($0.glucoseMgdl)
                }
                if let closest = matches.min(by: { lhs, rhs in
                    let left = abs(lhs.date.timeIntervalSince(target))
                    let right = abs(rhs.date.timeIntervalSince(target))
                    return left == right ? lhs.date < rhs.date : left < right
                }) {
                    pairs.append(Pair(prediction: prediction, actualDate: closest.date,
                                      actualMgdl: closest.glucoseMgdl))
                    changed = true
                } else if now < target.addingTimeInterval(45 * 60) {
                    // A late but timestamped reading can still arrive. Never
                    // fabricate an actual value from the latest live glucose.
                    remaining.append(prediction)
                } else {
                    changed = true
                }
            }
            pending = remaining
            if changed { result = Self.evaluate(pairs, timeZoneIdentifier: dayTimeZoneIdentifier) }
            return changed
        }

        static func evaluate(_ pairs: [Pair], timeZoneIdentifier: String) -> Result? {
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let byDay = Dictionary(grouping: pairs) {
                calendar.startOfDay(for: $0.prediction.referenceDate)
            }
            let latest = byDay.filter { $0.value.count >= minimumPairsPerDay }
                .sorted { $0.key < $1.key }.suffix(minimumUsableDays)
            guard latest.count == minimumUsableDays else { return nil }
            let common = latest.flatMap { $0.value }
            let engineMAE = common.reduce(0.0) {
                $0 + abs($1.prediction.engine60Mgdl - $1.actualMgdl)
            } / Double(common.count)
            let modelMAE = common.reduce(0.0) {
                $0 + abs($1.prediction.model60Mgdl - $1.actualMgdl)
            } / Double(common.count)
            guard engineMAE.isFinite, modelMAE.isFinite else { return nil }
            return Result(usableDays: latest.count, pairCount: common.count,
                          engineMAE: engineMAE, modelMAE: modelMAE)
        }

        func isValid() -> Bool {
            guard schemaVersion == Self.schemaVersion,
                  cutoff.timeIntervalSinceReferenceDate.isFinite,
                  TimeZone(identifier: dayTimeZoneIdentifier) != nil,
                  pending.allSatisfy({ prediction in
                      prediction.referenceDate >= cutoff &&
                          prediction.computedAt < prediction.targetDate.addingTimeInterval(-120) &&
                          !prediction.sensorID.isEmpty &&
                          (20...600).contains(prediction.engine60Mgdl) &&
                          (20...600).contains(prediction.model60Mgdl)
                  }),
                  pairs.allSatisfy({ pair in
                      pair.prediction.referenceDate >= cutoff &&
                          pair.prediction.computedAt < pair.actualDate &&
                          abs(pair.actualDate.timeIntervalSince(pair.prediction.targetDate)) <= 120 &&
                          (20...600).contains(pair.actualMgdl)
                  }),
                  result == Self.evaluate(pairs,
                      timeZoneIdentifier: dayTimeZoneIdentifier) else { return false }
            let references = pending.map { "\($0.sensorID):\($0.referenceDate.timeIntervalSince1970)" }
                + pairs.map { "\($0.prediction.sensorID):\($0.prediction.referenceDate.timeIntervalSince1970)" }
            return Set(references).count == references.count
        }
    }

    enum Status {
        case awaiting(usableDays: Int, pairs: Int)
        case passed(Result)
        case disabled(Result)
        case unreadable
    }

    private let directory: URL
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "glucose.forecast.ml.transition", qos: .utility)
    private var cached = [String: State]()
    private var invalidKeys = Set<String>()

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    private func key(modelID: String, cutoff: Date) -> String {
        "\(modelID)-\(String(cutoff.timeIntervalSince1970.bitPattern, radix: 16))"
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("transition-\(key).json")
    }

    private func marker(for key: String) -> String {
        "glucoseForecastML.transitionEvidence.\(key)"
    }

    private func invalidMarker(for key: String) -> String {
        "glucoseForecastML.transitionEvidenceInvalid.\(key)"
    }

    private func state(modelID: String, cutoff: Date) -> State? {
        guard GlucoseForecastMLStoragePolicy.isGeneratedUUID(modelID),
              cutoff.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let id = key(modelID: modelID, cutoff: cutoff)
        if invalidKeys.contains(id) || defaults.bool(forKey: invalidMarker(for: id)) {
            return nil
        }
        if let cached = cached[id] { return cached }
        let file = url(for: id)
        let loaded: State
        if fileManager.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(State.self, from: data),
                  decoded.isValid(),
                  decoded.modelID == modelID, decoded.cutoff == cutoff else {
                invalidKeys.insert(id)
                defaults.set(true, forKey: invalidMarker(for: id))
                return nil
            }
            defaults.set(true, forKey: marker(for: id))
            loaded = decoded
        } else {
            guard !defaults.bool(forKey: marker(for: id)) else {
                invalidKeys.insert(id)
                defaults.set(true, forKey: invalidMarker(for: id))
                return nil
            }
            loaded = State(modelID: modelID, cutoff: cutoff)
        }
        cached[id] = loaded
        return loaded
    }

    private func save(_ state: State) -> Bool {
        let id = key(modelID: state.modelID, cutoff: state.cutoff)
        do {
            try GlucoseForecastMLStoragePolicy.secureDirectory(directory)
            let file = url(for: id)
            // Persist the existence marker first. If an interrupted first write leaves
            // no file, a restart must fail closed instead of silently starting anew.
            defaults.set(true, forKey: marker(for: id))
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
            #if os(iOS)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                          ofItemAtPath: file.path)
            #endif
            cached[id] = state
            return true
        } catch {
            invalidKeys.insert(id)
            defaults.set(true, forKey: invalidMarker(for: id))
            return false
        }
    }

    func status(modelID: String, cutoff: Date) -> Status {
        queue.sync {
            guard let value = state(modelID: modelID, cutoff: cutoff) else { return .unreadable }
            if let result = value.result {
                return result.modelIsWorse ? .disabled(result) : .passed(result)
            }
            let dayCount = Dictionary(grouping: value.pairs) { pair -> Date in
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: value.dayTimeZoneIdentifier)!
                return calendar.startOfDay(for: pair.prediction.referenceDate)
            }.values.filter { $0.count >= State.minimumPairsPerDay }.count
            return .awaiting(usableDays: dayCount, pairs: value.pairs.count)
        }
    }

    func capture(_ prediction: Prediction, modelID: String, cutoff: Date,
                 onChange: @escaping () -> Void) {
        queue.async { [self] in
            guard var value = state(modelID: modelID, cutoff: cutoff),
                  value.add(prediction) else { return }
            if !save(value) { onChange() }
        }
    }

    func observe(_ readings: [GlucoseForecastSample], at now: Date,
                 modelID: String, cutoff: Date, onChange: @escaping () -> Void) {
        queue.async { [self] in
            guard var value = state(modelID: modelID, cutoff: cutoff),
                  value.observe(readings, at: now) else { return }
            _ = save(value)
            onChange()
        }
    }
}

final class GlucoseForecastMLManager: @unchecked Sendable {
    static let shared = GlucoseForecastMLManager()
    static let modelDidChange = Notification.Name("GlucoseForecastMLModelDidChange")
    static let statusDidChange = Notification.Name("GlucoseForecastMLStatusDidChange")

    private let lock = NSLock()
    private let store: GlucoseForecastMLModelStore
    private let transitionEvidence: GlucoseForecastMLTransitionEvidence
    private var loaded: GlucoseForecastMLLoadedBundle?
    private var loading = true
    private var isTraining = false
    private var progress: GlucoseForecastMLTrainingProgress?
    private var activeAttemptID: UUID?
    private var trainingTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private var lastOutcome: String?
    private var lastIssue: GlucoseForecastMLTrainingIssue?
    private var lastSelfCheck: GlucoseForecastMLSelfCheck?
    private var lastReviewCSVURL: URL?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var appHasResignedActive = false

    private init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("GlucoseForecastML", isDirectory: true)) {
        store = GlucoseForecastMLModelStore(directory: directory)
        transitionEvidence = GlucoseForecastMLTransitionEvidence(directory: directory)
        #if canImport(UIKit)
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { [weak self] _ in self?.cancelForBackground() })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.appHasResignedActive = false }
            })
        #endif
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let bundle = await self.store.loadActive()
            let review = self.store.loadReview()
            let reviewCSVURL = self.store.reviewCSVURL()
            self.lock.withLock {
                self.loaded = bundle
                self.lastSelfCheck = review
                self.lastReviewCSVURL = reviewCSVURL
                self.loading = false
            }
            self.notifyStatus()
            if bundle != nil { self.notifyModel() }
        }
    }

    var activeModelMetadata: GlucoseForecastMLModelMetadata? {
        lock.lock(); defer { lock.unlock() }
        return loaded?.metadata
    }

    var statusSummary: GlucoseForecastMLStatusSummary {
        lock.lock(); defer { lock.unlock() }
        return GlucoseForecastMLStatusSummary(
            isTraining: isTraining, progress: progress,
            activeModelID: loaded?.metadata.modelID,
            trainedAt: loaded?.metadata.trainedAt, lastAttempt: lastAttempt,
            lastOutcome: lastOutcome, lastIssue: lastIssue, lastSelfCheck: lastSelfCheck)
    }

    var selfCheckCSVURL: URL? { lock.withLock { lastReviewCSVURL } }

    /// Settings and inference use precisely the same verdict. A package appears
    /// here only after the store has reloaded and validated all six Core ML models.
    func compatibility(current: GlucoseForecastMLContext?)
        -> GlucoseForecastMLModelCompatibility.Assessment {
        guard let current else { return .invalid(.parametersChanged) }
        let bundle = lock.withLock { loaded }
        guard let bundle else { return .invalid(.packageUnavailable) }
        return compatibility(bundle: bundle, current: current)
    }

    private func compatibility(bundle: GlucoseForecastMLLoadedBundle,
                               current: GlucoseForecastMLContext)
        -> GlucoseForecastMLModelCompatibility.Assessment {
        let defaults = UserDefaults.standard
        let cutover = TreatmentSourceCutover.current(defaults: defaults)
        let base = GlucoseForecastMLModelCompatibility.assess(
            bundle.metadata, current: current, currentPolicy: defaults.dataFlowPolicy,
            cutover: cutover,
            restoreRequiresSetup: defaults.bool(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
                || TreatmentSourceCutover.hasInvalidStoredValue(defaults: defaults))
        guard case .transitionCompatible(let verifiedCutover) = base else { return base }
        switch transitionEvidence.status(modelID: bundle.metadata.modelID,
                                         cutoff: verifiedCutover.cutoff) {
        case .disabled: return .invalid(.prospectiveWorse)
        case .unreadable: return .invalid(.evidenceUnreadable)
        case .awaiting, .passed: return base
        }
    }

    func transitionStatus(current: GlucoseForecastMLContext?)
        -> GlucoseForecastMLTransitionEvidence.Status? {
        guard let current, let bundle = lock.withLock({ loaded }),
              case .transitionCompatible(let cutover) =
                  GlucoseForecastMLModelCompatibility.assess(
                      bundle.metadata, current: current,
                      currentPolicy: UserDefaults.standard.dataFlowPolicy,
                      cutover: TreatmentSourceCutover.current(),
                      restoreRequiresSetup: UserDefaults.standard.bool(
                          forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey))
        else { return nil }
        return transitionEvidence.status(modelID: bundle.metadata.modelID,
                                         cutoff: cutover.cutoff)
    }

    /// Cheap eligibility check before the independent, event-driven comparison.
    /// It deliberately does not depend on a Home presentation being visible.
    func needsTransitionObservation(context: GlucoseForecastMLContext) -> Bool {
        guard let bundle = lock.withLock({ loaded }) else { return false }
        if case .transitionCompatible = compatibility(bundle: bundle, current: context) {
            return true
        }
        return false
    }

    /// Freeze the exact engine and old model +60 values before the outcome exists.
    /// In particular, later retraining or changed settings cannot manufacture a pair.
    func recordTransitionPair(engine: GlucoseForecastResult,
                              modelForecast: GlucoseForecastMLForecast,
                              input: GlucoseForecastInput,
                              sourceSignature: String) {
        guard let bundle = lock.withLock({ loaded }),
              let context = GlucoseForecastMLContext(input: input,
                  sourceSignature: sourceSignature),
              case .transitionCompatible(let cutover) = compatibility(bundle: bundle,
                  current: context),
              let reference = engine.referenceDate,
              let sensorID = engine.referenceSensorID, !sensorID.isEmpty,
              modelForecast.modelID == bundle.metadata.modelID,
              let engine60 = engine.points.first(where: {
                  abs($0.date.timeIntervalSince(reference) - 3600) < 1
              })?.glucoseMgdl,
              let model60 = modelForecast.points.first(where: {
                  abs($0.date.timeIntervalSince(reference) - 3600) < 1
              })?.glucoseMgdl else { return }
        let prediction = GlucoseForecastMLTransitionEvidence.Prediction(
            referenceDate: reference, computedAt: input.now, sensorID: sensorID,
            engine60Mgdl: engine60, model60Mgdl: model60)
        transitionEvidence.capture(prediction, modelID: bundle.metadata.modelID,
            cutoff: cutover.cutoff) { [weak self] in self?.notifyStatus() }
    }

    func observeTransition(readings: [GlucoseForecastSample], at now: Date,
                           context: GlucoseForecastMLContext) {
        guard let bundle = lock.withLock({ loaded }),
              case .transitionCompatible(let cutover) = compatibility(bundle: bundle,
                  current: context) else { return }
        transitionEvidence.observe(readings, at: now,
            modelID: bundle.metadata.modelID, cutoff: cutover.cutoff) { [weak self] in
                self?.notifyStatus()
                self?.notifyModel()
            }
    }

    func shouldTrain(context: GlucoseForecastMLContext, now: Date = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !loading, !isTraining else { return false }
        guard let metadata = loaded?.metadata else { return true }
        return metadata.context != context
            || now.timeIntervalSince(metadata.trainedAt) > GlucoseForecastMLChronology.modelAgeLimit
    }

    func requestTraining(examples: [GlucoseForecastMLReplayExample],
                         context: GlucoseForecastMLContext, force: Bool = false) {
        #if canImport(CreateML)
        lock.lock()
        let due: Bool
        if let metadata = loaded?.metadata {
            due = metadata.context != context
                || Date().timeIntervalSince(metadata.trainedAt) > GlucoseForecastMLChronology.modelAgeLimit
        } else { due = true }
        guard !loading, !isTraining, !appHasResignedActive, force || due else {
            lock.unlock()
            return
        }
        isTraining = true
        let attemptID = UUID()
        activeAttemptID = attemptID
        progress = .trainingModels(completed: 0, total: 12)
        lastAttempt = .now
        lastOutcome = nil
        lastIssue = nil
        let active = loaded
        lock.unlock()
        notifyStatus()
        let task = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            #if canImport(UIKit)
            let foreground = await MainActor.run { UIApplication.shared.applicationState == .active }
            if !foreground {
                self.finish(outcome: "backgroundCancelled", report: nil, attemptID: attemptID)
                return
            }
            #endif
            let sessions: URL
            do {
                sessions = try self.store.prepareTrainingSession()
            } catch {
                self.finish(outcome: "trainingFailed", report: nil, attemptID: attemptID)
                return
            }
            defer { self.store.finishTrainingSession(sessions) }
            do {
                let candidate = try await GlucoseForecastMLTrainer.train(
                    examples: examples, context: context, active: active,
                    sessionsDirectory: sessions, onProgress: { [weak self] progress in
                        self?.recordProgress(progress, attemptID: attemptID)
                    })
                try Task.checkCancellation()
                if candidate.metadata.selfCheck.promoted {
                    #if canImport(UIKit)
                    let stillCurrent = await MainActor.run {
                        UIApplication.shared.applicationState == .active &&
                            GlucoseForecastDataAdapter.presentationInputSignature(
                                horizonMinutes: 120) == context.sourceSignature
                    }
                    guard stillCurrent else { throw CancellationError() }
                    #endif
                    self.recordProgress(.installing, attemptID: attemptID)
                    let bundle = try await self.store.install(candidate)
                    self.lock.withLock { self.loaded = bundle }
                    let reviewSaved = (try? self.store.saveReview(
                        candidate.metadata, rows: candidate.reviewRows)) != nil
                    self.lock.withLock {
                        self.lastReviewCSVURL = reviewSaved ? self.store.reviewCSVURL() : nil
                    }
                    self.notifyModel()
                    self.finish(outcome: "activated", report: candidate.metadata.selfCheck,
                                attemptID: attemptID)
                } else {
                    let reviewSaved = (try? self.store.saveReview(
                        candidate.metadata, rows: candidate.reviewRows)) != nil
                    self.lock.withLock {
                        self.lastReviewCSVURL = reviewSaved ? self.store.reviewCSVURL() : nil
                    }
                    self.finish(outcome: "rejected", report: candidate.metadata.selfCheck,
                                attemptID: attemptID)
                }
            } catch is CancellationError {
                self.finish(outcome: "backgroundCancelled", report: nil, attemptID: attemptID)
            } catch let issue as GlucoseForecastMLTrainingIssue {
                self.finish(outcome: "trainingIssue", report: nil, attemptID: attemptID,
                            issue: issue)
            } catch let failure as GlucoseForecastMLTrainingFailure {
                self.finish(outcome: failure.rawValue, report: nil, attemptID: attemptID)
            } catch {
                self.finish(outcome: "trainingFailed", report: nil, attemptID: attemptID)
            }
        }
        lock.lock()
        if isTraining { trainingTask = task } else { task.cancel() }
        lock.unlock()
        #else
        lock.lock()
        lastAttempt = .now
        lastOutcome = GlucoseForecastMLTrainingFailure.trainingUnavailable.rawValue
        lock.unlock()
        notifyStatus()
        #endif
    }

    func infer(input: GlucoseForecastInput,
               result: GlucoseForecastResult, sourceSignature: String) -> GlucoseForecastMLForecast? {
        guard result.reason == nil, result.referenceDate != nil,
              let context = GlucoseForecastMLContext(input: input, sourceSignature: sourceSignature) else { return nil }
        lock.lock()
        let bundle = loaded
        lock.unlock()
        guard let bundle, let reference = result.referenceDate else { return nil }
        let assessment = compatibility(bundle: bundle, current: context)
        if case .invalid = assessment { return nil }
        let selected = GlucoseForecastMLChronology.horizons.filter { $0 <= input.horizonMinutes }
        guard !selected.isEmpty else { return nil }
        var knots = [GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0)]
        for horizon in selected {
            guard let row = GlucoseForecastMLFeatures.row(
                input: input, result: result, horizonMinutes: horizon),
                  row.referenceDate == reference,
                  let correction = bundle.prediction(kind: "correction", horizon: horizon, row: row),
                  let capped = GlucoseForecastMLChronology.clampedCorrection(correction),
                  GlucoseForecastMLChronology.finalGlucose(engine: row.engineValue,
                                                          correction: correction) != nil,
                  let rawError = bundle.prediction(kind: "error", horizon: horizon, row: row),
                  let error = GlucoseForecastMLChronology.positiveError(rawError),
                  let calibration = bundle.metadata.calibrations[horizon],
                  calibration.count >= GlucoseForecastMLChronology.minimumCalibrationRows,
                  calibration.multiplier.isFinite, calibration.multiplier > 0 else { return nil }
            let width = error * calibration.multiplier
            guard width.isFinite, width >= 0 else { return nil }
            knots.append(GlucoseForecastMLChronology.Knot(
                minute: horizon, correction: capped, halfWidth: width))
        }
        guard let overlay = GlucoseForecastMLChronology.assemble(
            engine: result.points.map(\.glucoseMgdl), knots: knots,
            horizonMinutes: input.horizonMinutes) else { return nil }
        let points = zip(result.points, overlay.central).map {
            GlucoseForecastPoint(date: $0.0.date, glucoseMgdl: $0.1)
        }
        let band = zip(result.points, zip(overlay.central, overlay.halfWidth)).map {
            GlucoseForecastMLBandPoint(date: $0.0.date,
                lowerMgdl: $0.1.0 - $0.1.1, upperMgdl: $0.1.0 + $0.1.1)
        }
        guard points.count == result.points.count, !points.isEmpty else { return nil }
        return GlucoseForecastMLForecast(points: points, band: band,
                                         modelID: bundle.metadata.modelID)
    }

    private func cancelForBackground() {
        lock.lock()
        appHasResignedActive = true
        let task = trainingTask
        lock.unlock()
        task?.cancel()
    }

    private func recordProgress(_ newProgress: GlucoseForecastMLTrainingProgress,
                                attemptID: UUID) {
        lock.lock()
        guard isTraining, activeAttemptID == attemptID else { lock.unlock(); return }
        progress = newProgress
        lock.unlock()
        notifyStatus()
    }

    private func finish(outcome: String, report: GlucoseForecastMLSelfCheck?,
                        attemptID: UUID, issue: GlucoseForecastMLTrainingIssue? = nil) {
        lock.lock()
        guard activeAttemptID == attemptID else { lock.unlock(); return }
        isTraining = false
        progress = nil
        activeAttemptID = nil
        trainingTask = nil
        lastOutcome = outcome
        lastIssue = issue
        if let report { lastSelfCheck = report }
        lock.unlock()
        notifyStatus()
    }

    private func notifyModel() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.modelDidChange, object: nil)
        }
    }

    private func notifyStatus() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }
}
