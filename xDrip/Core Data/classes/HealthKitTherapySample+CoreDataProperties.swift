//
//  HealthKitTherapySample+CoreDataProperties.swift
//  xdrip
//

import CoreData
import Foundation

extension HealthKitTherapySample {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<HealthKitTherapySample> {
        NSFetchRequest<HealthKitTherapySample>(entityName: "HealthKitTherapySample")
    }

    /// The HealthKit sample UUID, unique across replayed anchored-query pages.
    @NSManaged public var uuid: String
    /// The quantity identifier: insulinDelivery or dietaryCarbohydrates.
    @NSManaged public var kind: String
    @NSManaged public var sourceBundleIdentifier: String
    @NSManaged public var sourceName: String
    /// Original interval; neither date is replaced with the import timestamp.
    @NSManaged public var startDate: Date
    @NSManaged public var endDate: Date
    /// International units for insulin or grams for carbohydrates.
    @NSManaged public var quantity: Double
    /// Bolus, basal, uncertain, carbohydrate, or another documented import state.
    @NSManaged public var classification: String
    @NSManaged public var externalUUID: String?
    @NSManaged public var syncIdentifier: String?
    /// Set only after a matching HealthKit deleted-object event.
    @NSManaged public var wasDeletedInHealthKit: Bool
}
