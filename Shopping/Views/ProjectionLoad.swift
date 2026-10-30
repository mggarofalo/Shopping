/// The read state of a screen projection.
///
/// An empty `.loaded` value is the only state that may show empty-state copy.
/// Views must never use an empty value to stand in for "not read yet".
enum ProjectionLoad<Value> {
    case loading
    case loaded(Value)
    case failed

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}

extension ProjectionLoad: Equatable where Value: Equatable {}
