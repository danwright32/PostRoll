import Foundation

/// Where work that BLOCKS a thread goes (#1143).
///
/// `Task.detached` does not give work a thread of its own. It puts it on
/// Swift's COOPERATIVE POOL, which is sized to the machine's cores and does not
/// grow. A blocked item there occupies a pool thread doing nothing, and enough
/// of them starve every other piece of concurrent work in the process (L241).
///
/// The tell is what makes this expensive to diagnose rather than expensive to
/// suffer: the failure is far larger than its cause and points everywhere at
/// once. It does not present as the blocked operation complaining, it presents
/// as everything else stopping. downbeat#406 on 2026-08-22 was the same fix
/// applied the same way in a sibling app, where a suite whose fixtures blocked a
/// handful of cooperative threads killed the test process partway through and
/// reported 1,835 failures that were one starved runtime.
///
/// So blocking work goes to libdispatch's global pool instead, which DOES add
/// threads when the ones it has are stuck. That is the whole difference, and it
/// is the only reason this type exists.
///
/// ## What counts as blocking
///
/// Waiting on something OUTSIDE this process, with no bound this side can
/// enforce: a subprocess that has to exit, a semaphore something else has to
/// signal, a read that may go to the network. Not work that merely takes a
/// while: decoding an image, walking a directory or scanning a store are CPU
/// and local disk, they always finish, and the cooperative pool is exactly
/// where they belong.
///
/// `tests/test_blocking_work_stays_off_the_cooperative_pool.py` enumerates the
/// first kind from the source rather than from a list kept here, so a function
/// that starts waiting on a subprocess becomes a subject of that check on the
/// day it does (L96, L247).
///
/// ## Why not just make the callee async
///
/// Because these callees are synchronous by nature: they are `Process` plus
/// `waitUntilExit`, or a `DispatchSemaphore`. `ProcessRunner.run` shows the
/// better answer where it is available, bridging termination through a
/// continuation so nothing waits at all. Everything that cannot be written that
/// way comes here.
enum Blocking {

    /// Run `work` off the cooperative pool and hand back what it returned.
    ///
    /// `qos` is passed through rather than fixed, because the call sites differ in
    /// urgency: a launch reading the checkout is `.userInitiated` and a
    /// background freshness check is not, and flattening them would either make
    /// the quiet work compete with the visible work or the reverse.
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .utility,
                                 _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }
}
