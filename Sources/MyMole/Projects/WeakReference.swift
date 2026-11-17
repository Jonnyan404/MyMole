// A weak reference that may cross an isolation domain.
//
// Detached scans are handed a reference to the main-actor model so they can
// report progress back. Capturing the model weakly inside the detached task and
// then sending it into a main-actor closure trips Swift 6.2's region isolation
// checker ("task-isolated 'self' is captured by a main actor-isolated
// closure"). The reference is made once on the main actor and handed over as a
// value that is safe to send; the model inside is only ever touched from the
// main actor, which is what the original weak capture did too.
final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
