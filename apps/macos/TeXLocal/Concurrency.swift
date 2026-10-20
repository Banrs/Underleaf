import Observation

/// Applies observable state's value as it changes, a turn later: changes made together arrive as the last. A view that
/// must draw a change in the frame it is made in observes with `withObservationTracking`.
func track<Value: Sendable & Equatable>(_ value: @escaping @MainActor @Sendable () -> Value, initial: Bool = true,
                                          _ apply: @escaping @MainActor (Value) -> Void) -> Task<Void, Never> {
    Task {
        var last: Value?
        for await next in Observations(value) where next != last {
            if last != nil || initial { apply(next) }
            last = next
        }
    }
}

/// `work` in `slot` in place of what ran there, which is cancelled.
func restart<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    slot?.cancel()
    let task = Task { await work() }
    slot = task
    return task
}

/// `work` once `delay` has passed, unless the next of its kind cancels it first.
func restart(_ slot: inout Task<Void, Never>?, after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
    slot?.cancel()
    slot = Task {
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { await work() }
    }
}

/// `work` in `slot` once what is there has finished: one at a time, in the order asked.
func enqueue<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    let previous = slot
    let task = Task {
        _ = await previous?.value
        return await work()
    }
    slot = task
    return task
}
