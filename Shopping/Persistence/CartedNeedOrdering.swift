enum CartedNeedOrdering {
    static func ordered(_ needs: [Need]) -> [Need] {
        needs.sorted {
            switch ($0.cartedAt, $1.cartedAt) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            default:
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }
}
