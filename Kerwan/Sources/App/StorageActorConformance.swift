import KerwanStorage

// MARK: - StorageActor: AppStorageService

/// Declares that `StorageActor` (from `KerwanStorage`) conforms to the
/// `AppStorageService` protocol defined in the `Kerwan` app target.
///
/// The protocol requirements are satisfied by existing methods on `StorageActor`.
/// Swift allows non-async actor methods to satisfy async protocol requirements,
/// and non-throwing methods to satisfy throwing requirements.
extension StorageActor: AppStorageService {}
