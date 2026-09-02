/// constants used in calibration algorithm
enum ConstantsCalibrationAlgorithms {
    // age adjustment constants, only for non Libre
    static let ageAdjustmentTime = 86400000 * 1.9
    static let ageAdjustmentFactor = 0.45
    
    // minimum and maxium values for a reading
    static let minimumBgReadingCalculatedValue = 39.0
    static let maximumBgReadingCalculatedValue = 400.0
    static let maximumBgReadingCalculatedValueLimit = 600.0
    static let bgReadingErrorValue = 38.0

    // recommended maximum difference between current glucose and a single calibration step
    // especially relevant for Dexcom native calibrations to avoid rejection
    static let maximumRecommendedCalibrationDifferenceInMgDl = 30.0
}

enum BgReadingDownstreamValidity: Equatable {
    case valid
    case incomplete
    case internalCalibrationError
    case nonFinite
}

/// Keeps the calibrator's internal 38 marker out of every downstream consumer without
/// treating physiological values by number alone. A native/factory reading has its raw and
/// calculated values in the same domain and no age-adjusted xDrip input; a calibrated reading
/// uses the sentinel only when the calculation failed before the normal 39 mg/dL clamp.
struct BgReadingDownstreamPolicy {
    static func validity(
        calculatedValue: Double,
        rawData: Double,
        ageAdjustedRawValue: Double,
        finalValue: Double,
        calibrationUsesErrorSentinel: Bool? = nil
    ) -> BgReadingDownstreamValidity {
        guard calculatedValue.isFinite, rawData.isFinite,
              ageAdjustedRawValue.isFinite, finalValue.isFinite
        else { return .nonFinite }

        guard calculatedValue != 0, finalValue > 0 else { return .incomplete }

        let isErrorSentinel: Bool
        if let calibrationUsesErrorSentinel {
            isErrorSentinel = calibrationUsesErrorSentinel
                && calculatedValue == ConstantsCalibrationAlgorithms.bgReadingErrorValue
        } else {
            let isNativePassThrough = ageAdjustedRawValue == 0
                && rawData == ConstantsCalibrationAlgorithms.bgReadingErrorValue
                && calculatedValue == rawData
            isErrorSentinel = calculatedValue == ConstantsCalibrationAlgorithms.bgReadingErrorValue
                && !isNativePassThrough
        }

        return isErrorSentinel ? .internalCalibrationError : .valid
    }
}
