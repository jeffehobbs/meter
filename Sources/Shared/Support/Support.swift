import Foundation
import os.lock

// MARK: - Clock

/// Monotonic seconds. Everything that measures time — the transport, the
/// director's gesture clocks, the UI's pulse — reads the same ruler.
enum Clock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
    }()

    static func now() -> Double { Double(mach_absolute_time()) * scale }
}

// MARK: - Primes

/// Meter leans on primes for the same reason Echo does: if every recurring
/// decision runs on a prime number of measures, no two of them ever line up
/// twice in a session, and the groove never settles into an audible loop of
/// loops.
enum Primes {
    /// Gesture periods, in measures. The director's reallocations run on these.
    static let gesturePeriods = [5, 7, 11, 13, 17, 19, 23, 29]

    /// Small primes used to offset each voice's placement decisions from every
    /// other voice's, so two lanes never re-roll their steps on the same bar.
    static let small = [2, 3, 5, 7, 11, 13, 17, 19, 23]

    /// A prime step coprime with `count`, so repeated stepping visits every
    /// slot before returning to the start.
    static func step(for count: Int, seed: Int) -> Int {
        guard count > 1 else { return 1 }
        let candidates = small.filter { count % $0 != 0 }
        guard !candidates.isEmpty else { return 1 }
        return candidates[abs(seed) % candidates.count]
    }
}

// MARK: - Deterministic randomness

/// Small xorshift. Deterministic so a session can be reproduced from a seed,
/// and self-contained so the composition path never touches the system RNG.
struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    static func freshSeed() -> UInt64 {
        UInt64(bitPattern: Int64(Clock.now() * 1_000_000)) | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : min(n - 1, Int(unit() * Double(n))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }

    /// Weighted pick. Weights need not be normalized; non-positive weights are
    /// skipped. Returns nil only when every weight is non-positive.
    mutating func pick<T>(_ xs: [T], weights: [Double]) -> T? {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0, xs.count == weights.count else { return nil }
        var r = unit() * total
        for (x, w) in zip(xs, weights) where w > 0 {
            r -= w
            if r <= 0 { return x }
        }
        return xs.last
    }
}

// MARK: - Ramps

/// The one rule Meter inherits from Thrum's Flow: nothing is ever *set*, it is
/// ramped. A share that jumps from 0.2 to 0.4 between two measures is an event
/// the ear catches; the same move spread over six measures on a curve with zero
/// velocity at both ends is just the music going somewhere.
struct Ramp {
    let from: Double
    let to: Double
    let start: Double      // in measures
    let duration: Double   // in measures

    /// Smootherstep — zero velocity *and* zero acceleration at both ends.
    /// Ordinary smoothstep still has an acceleration step at the ends, which on
    /// a long slide is audible as the moment the movement starts.
    func value(at t: Double) -> Double {
        let x = min(1, max(0, (t - start) / max(0.001, duration)))
        let e = x * x * x * (x * (x * 6 - 15) + 10)
        return from + (to - from) * e
    }

    func done(at t: Double) -> Bool { t >= start + duration }
}

// MARK: - Lock-guarded event queue

/// Fixed-capacity queue from the transport thread to the render thread. The
/// render side drains with a try-lock so it never blocks; the writer holds the
/// lock only long enough to copy a struct.
final class EventQueue<T> {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<T>
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>

    init(capacity: Int = 512) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    func push(_ event: T) {
        os_unfair_lock_lock(lock)
        if count < capacity {
            storage[count] = event
            count += 1
        }
        os_unfair_lock_unlock(lock)
    }

    /// Drains that found the lock held by a writer. The render thread will not
    /// wait for one, so a contended push costs the hits in the queue a whole
    /// buffer — worth counting rather than guessing at.
    private(set) var skipped = 0

    func drain(_ body: (T) -> Void) {
        guard os_unfair_lock_trylock(lock) else { skipped += 1; return }
        for i in 0..<count { body(storage[i]) }
        count = 0
        os_unfair_lock_unlock(lock)
    }
}

// MARK: - Largest remainder

/// Split `total` whole units across `weights` so the parts sum to exactly
/// `total`. This is what makes the budget a budget rather than a target: every
/// measure spends all of it, and the only question is who gets what.
func apportion(total: Int, weights: [Double]) -> [Int] {
    guard total > 0, !weights.isEmpty else { return Array(repeating: 0, count: weights.count) }
    let sum = weights.reduce(0) { $0 + max(0, $1) }
    guard sum > 0 else { return Array(repeating: 0, count: weights.count) }

    var quota = [Double](repeating: 0, count: weights.count)
    var parts = [Int](repeating: 0, count: weights.count)
    for i in weights.indices {
        quota[i] = Double(total) * max(0, weights[i]) / sum
        parts[i] = Int(quota[i])
    }
    // Hand out what rounding left over, largest fractional remainder first.
    var left = total - parts.reduce(0, +)
    let order = weights.indices.sorted { (quota[$0] - Double(parts[$0])) > (quota[$1] - Double(parts[$1])) }
    var i = 0
    while left > 0 && !order.isEmpty {
        parts[order[i % order.count]] += 1
        left -= 1
        i += 1
    }
    return parts
}
