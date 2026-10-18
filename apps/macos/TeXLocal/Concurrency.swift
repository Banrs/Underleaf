import Observation

// Helpers for work that outlives a call: the model watching, and tasks that replace or follow one another.

/// Applies the value of observable state each time it changes to something new, once a turn on: changes made together
/// reach `apply` as the last of them, and a change back to what was applied is none. `initial` off leaves the value
/// the state has now. For a view that can lag a turn behind its model; the toolbar's `WorkspaceToolbar.watch` applies
/// each change as it is made instead, as a column's resize refits the PDF during layout and the toolbar must draw
/// that frame once, not twice.
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

/// `work` in `slot` in place of what ran there, which is cancelled: only the latest of its kind carries on. Its
/// task, for a caller that waits for it.
func restart<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    slot?.cancel()
    let task = Task { await work() }
    slot = task
    return task
}

/// `work` once `delay` has passed, in `slot` in place of what waited there, which is cancelled: the next of its kind
/// cancels this one, and one cancelled does nothing.
func restart(_ slot: inout Task<Void, Never>?, after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
    slot?.cancel()
    slot = Task {
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { await work() }
    }
}

/// `work` in `slot` after what is there has finished, which is not cancelled: one at a time, in the order asked. Its
/// task, for a caller that waits for it.
func enqueue<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    let previous = slot
    let task = Task {
        _ = await previous?.value
        return await work()
    }
    slot = task
    return task
}
