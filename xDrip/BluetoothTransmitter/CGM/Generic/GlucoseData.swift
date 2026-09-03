import Foundation

/// glucose,
public class GlucoseData {
    
    var timeStamp:Date

    var glucoseLevelRaw:Double

    var backfilledAt: Date?

    /// Stable source identity for idempotent Watch delivery (not a new transport field).
    var sourceIdentifier: String?

    /// used when needed
    var slopeOrdinal: Int?
    
    /// used when needed
    var slopeName: String?
    
    init(timeStamp:Date, glucoseLevelRaw:Double, backfilledAt: Date? = nil) {
        
        self.timeStamp = timeStamp
        
        self.glucoseLevelRaw = glucoseLevelRaw

        self.backfilledAt = backfilledAt
        
    }
    
    init(timeStamp:Date, glucoseLevelRaw:Double, backfilledAt: Date? = nil, slopeOrdinal: Int, slopeName: String) {
        
        self.timeStamp = timeStamp
        
        self.glucoseLevelRaw = glucoseLevelRaw

        self.backfilledAt = backfilledAt
        
        self.slopeOrdinal = slopeOrdinal
        
        self.slopeName = slopeName
        
    }

    var description: String {
        
        return "timeStamp = " + timeStamp.description(with: .current) + ", glucoseLevelRaw = " + glucoseLevelRaw.description
        
    }
    
}
