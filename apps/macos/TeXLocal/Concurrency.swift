import Observation

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

func restart<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    slot?.cancel()
    let task = Task { await work() }
    slot = task
    return task
}

func restart(_ slot: inout Task<Void, Never>?, after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
    slot?.cancel()
    slot = Task {
        try? await Task.sleep(for: delay)
        if !Task.isCancelled { await work() }
    }
}

func enqueue<T: Sendable>(_ slot: inout Task<T, Never>?, _ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
    let previous = slot
    let task = Task {
        _ = await previous?.value
        return await work()
    }
    slot = task
    return task
}
