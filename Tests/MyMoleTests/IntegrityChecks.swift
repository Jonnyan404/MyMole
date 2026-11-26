import Foundation
import Testing

/// After a move: nothing under `root` changed but what moved. After Undo
/// (`moved` empty): everything is exactly as it was. `excluding`: a
/// panel's own stores kept beside what it works on.
func expectOnlyMoved(_ moved: [String], in root: String, since before: TreeFingerprint, excluding: [String] = [],
                     sourceLocation: SourceLocation = #_sourceLocation) throws {
    let rel = moved.map { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : $0 }
    let now = try TreeFingerprint(root, excluding: excluding)
    let was = before.outside(rel), now2 = now.outside(rel)
    #expect(now2 == was, "\(TreeFingerprint.differences(was, now2))", sourceLocation: sourceLocation)
    // What moved is really gone from here.
    for r in rel { #expect(now.items[r] == nil, "\(r) is still there", sourceLocation: sourceLocation) }
}
