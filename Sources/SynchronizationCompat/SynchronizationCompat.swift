// Back-deployment shim for Swift's Synchronization module.
//
// The standard library annotates Mutex and Atomic as macOS 15.0+, but this
// build targets macOS 14 (an OCLP-upgraded Intel Mac). The API surface this
// package actually uses is small — Mutex.withLock, and Atomic's
// load/store/exchange/add with .relaxed ordering — so it is provided here on
// top of OSAllocatedUnfairLock, which exists from macOS 13.
//
// Ordering arguments are accepted for source compatibility and ignored: every
// operation is performed under a lock, which is sequentially consistent and so
// satisfies any weaker ordering a caller asks for. The cost is a lock
// acquisition per operation on counters that were previously lock-free; the
// callers here are disk scanners where the enclosing work dominates.
import os

public enum AtomicOrdering: Equatable, Sendable {
    case relaxed
    case acquiring
    case releasing
    case acquiringAndReleasing
    case sequentiallyConsistent
}

public struct Mutex<Value>: @unchecked Sendable {
    private let storage: Storage

    public init(_ value: Value) {
        storage = Storage(value)
    }

    /// Runs `body` while holding the lock. Reentrant calls from the same thread
    /// deadlock, exactly as the standard library's Mutex does.
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        try storage.withLock(body)
    }

    // The lock lives in an allocated os_unfair_lock rather than a stored
    // instance property: taking the address of a class property would hand out
    // a pointer Swift's exclusivity checking does not own. OSAllocatedUnfairLock
    // would work too, but it requires the state to be Sendable, which the
    // standard library's Mutex does not.
    private final class Storage: @unchecked Sendable {
        private let lock: UnsafeMutablePointer<os_unfair_lock>
        private var value: Value

        init(_ value: Value) {
            self.value = value
            lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
            lock.initialize(to: os_unfair_lock())
        }

        deinit {
            lock.deinitialize(count: 1)
            lock.deallocate()
        }

        func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return try body(&value)
        }
    }
}

public struct Atomic<Value>: @unchecked Sendable {
    private let storage: Mutex<Value>

    public init(_ value: Value) {
        storage = Mutex(value)
    }

    public func load(ordering: AtomicOrdering = .relaxed) -> Value {
        storage.withLock { $0 }
    }

    public func store(_ desired: Value, ordering: AtomicOrdering = .relaxed) {
        storage.withLock { $0 = desired }
    }

    @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicOrdering = .relaxed) -> Value {
        storage.withLock { value in
            let previous = value
            value = desired
            return previous
        }
    }
}

extension Atomic where Value: Equatable {
    @discardableResult
    public func compareExchange(
        expected: Value,
        desired: Value,
        ordering: AtomicOrdering = .relaxed
    ) -> (exchanged: Bool, original: Value) {
        storage.withLock { value in
            guard value == expected else { return (false, value) }
            let original = value
            value = desired
            return (true, original)
        }
    }
}

extension Atomic where Value: FixedWidthInteger {
    @discardableResult
    public func add(
        _ delta: Value,
        ordering: AtomicOrdering = .relaxed
    ) -> (oldValue: Value, newValue: Value) {
        storage.withLock { value in
            let old = value
            value += delta
            return (old, value)
        }
    }

    @discardableResult
    public func subtract(
        _ delta: Value,
        ordering: AtomicOrdering = .relaxed
    ) -> (oldValue: Value, newValue: Value) {
        storage.withLock { value in
            let old = value
            value -= delta
            return (old, value)
        }
    }
}
