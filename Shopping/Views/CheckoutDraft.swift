import Foundation

struct CheckoutDraft: Identifiable {
    let preview: ClearCartedPreview
    let householdID: UUID
    let listID: UUID

    var id: UUID { preview.token.id }
}
