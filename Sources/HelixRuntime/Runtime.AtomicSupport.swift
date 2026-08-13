#if canImport(HelixCore)
import HelixRuntimeSupport
#endif

extension Runtime {
final class AtomicFlag: @unchecked Sendable {
    private let storage: OpaquePointer

    init(_ initialValue: Bool = false) {
        guard let storage = helix_runtime_atomic_flag_create(initialValue) else {
            fatalError("Helix Runtime could not allocate an atomic flag")
        }
        self.storage = storage
    }

    deinit {
        helix_runtime_atomic_flag_destroy(storage)
    }

    func loadAcquire() -> Bool {
        helix_runtime_atomic_flag_load_acquire(storage)
    }

    func storeRelease(_ value: Bool) {
        helix_runtime_atomic_flag_store_release(storage, value)
    }
}

final class AtomicReference<Instance: AnyObject>: @unchecked Sendable {
    private let storage: OpaquePointer
    // The pointee is immutable after publication. This strong reference owns
    // it for at least as long as any acquire load can observe the raw pointer.
    private var retained: Instance?

    init() {
        guard let storage = helix_runtime_atomic_pointer_create() else {
            fatalError("Helix Runtime could not allocate an atomic reference")
        }
        self.storage = storage
    }

    deinit {
        helix_runtime_atomic_pointer_destroy(storage)
    }

    func storeOnce(_ instance: Instance) {
        precondition(retained == nil, "an atomic reference can be published only once")
        retained = instance
        helix_runtime_atomic_pointer_store_release(
            storage,
            Unmanaged.passUnretained(instance).toOpaque()
        )
    }

    func loadAcquire() -> Instance? {
        guard let pointer = helix_runtime_atomic_pointer_load_acquire(storage) else {
            return nil
        }
        return Unmanaged<Instance>.fromOpaque(pointer).takeUnretainedValue()
    }
}
}
