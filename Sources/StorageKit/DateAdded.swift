import Darwin

/// Finder's "Date Added": when an item came into the folder it's in. A
/// move to the Trash and back sets it to the time of the move, so a move
/// keeps the old one and Undo puts it back. Disks that don't keep it give nil.
public enum DateAdded {
    /// Nanoseconds since 1970, read without following a link at the end.
    public static func read(_ path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ADDEDTIME)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &buffer, buffer.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int64? in
            // Length, then the attributes the disk returned, then the time.
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_ADDEDTIME) != 0 else { return nil }
            let at = 4 + MemoryLayout<attribute_set_t>.size
            let ts = raw.loadUnaligned(fromByteOffset: at, as: timespec.self)
            return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        }
    }

    /// Sets it on `name` in the open folder `dir`, never through a link.
    @discardableResult
    public static func set(_ nanoseconds: Int64, on name: String, in dir: Int32) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        var ts = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
        return setattrlistat(dir, name, &list, &ts, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0
    }
}
