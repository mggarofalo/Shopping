import Foundation

struct CheckoutResult {
    let operationID: UUID
    let householdID: UUID
    let listID: UUID
    let cleared: Int
    let skipped: Int
    var isIndividualRemoval = false
}
