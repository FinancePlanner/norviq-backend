enum ConstantTime {
    /// Compares two secrets without a data-dependent early return.
    ///
    /// Swift's `String ==` short-circuits on the first differing byte, which is a timing oracle
    /// for brute-forcing a shared secret. This folds every byte into the accumulator so the
    /// running time does not reveal how many leading bytes matched.
    static func equals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let count = max(a.count, b.count)
        for i in 0 ..< count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
