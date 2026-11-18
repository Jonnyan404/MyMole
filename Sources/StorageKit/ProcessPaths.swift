import Darwin
import Foundation

/// Where running programs are at work: the folder each stands in and the
/// files each has open. A folder that looks left alone can still be a
/// waiting script's working folder, with no file open in it, or hold a log a
/// program writes once an hour. Only programs this user may look at answer,
/// which are the ones that work in this user's folders.
public enum ProcessPaths {
    /// Every working folder and open file, as full paths; nil when the
    /// programs couldn't be listed, so "none" is never taken for an answer.
    public static func inUse(excluding own: pid_t = getpid()) -> Set<String>? {
        let wanted = proc_listallpids(nil, 0)
        guard wanted > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(wanted) + 256)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }
        var paths = Set<String>()
        for pid in pids.prefix(Int(got)) where pid > 0 && pid != own {
            var folders = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &folders, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                let path = text(&folders.pvi_cdir.vip_path)
                if path.count > 1 { paths.insert(path) }
            }
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var files = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let read = files.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard read > 0 else { continue }
            for file in files.prefix(Int(read) / MemoryLayout<proc_fdinfo>.size) where file.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = text(&info.pvip.vip_path)
                if path.count > 1 { paths.insert(path) }
            }
        }
        return paths
    }

    /// Whether something in `paths` is `folder` itself or inside it.
    public static func uses(_ folder: String, among paths: Set<String>) -> Bool {
        paths.contains(folder) || paths.contains { $0.hasPrefix(folder + "/") }
    }

    /// Every path in `paths` and every folder above each, so that whether a
    /// folder holds one of them is one lookup, however many folders are asked.
    public static func foldersInUse(_ paths: Set<String>) -> Set<String> {
        var all = paths
        for path in paths {
            var rest = Substring(path)
            while let slash = rest.lastIndex(of: "/"), slash > rest.startIndex {
                rest = rest[..<slash]
                guard all.insert(String(rest)).inserted else { break }
            }
        }
        return all
    }

    private static func text<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
