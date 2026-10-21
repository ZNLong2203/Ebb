import Foundation

/// A directory, or a file big enough to be worth drawing, in the scanned tree.
///
/// Small files are only summed into their directory, and directories under
/// `Scanner.pruneBelow` drop their children once measured. That keeps a scan of
/// millions of files to a few tens of MB.
final class ScanNode: Identifiable {
    let name: String
    let isDirectory: Bool
    /// Allocated bytes on disk, including everything beneath.
    var size: Int64 = 0
    /// Files beneath this node (all of them, not just the ones kept as nodes).
    var fileCount = 0
    var modified: Date
    var children: [ScanNode] = []
    weak var parent: ScanNode?

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool, modified: Date) {
        self.name = name
        self.isDirectory = isDirectory
        self.modified = modified
    }

    /// The root keeps its full path as its name, so walking up rebuilds any path.
    var path: String {
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    /// Bytes in this directory that aren't represented by a child node (small files, pruned dirs' leftovers).
    var looseBytes: Int64 { max(0, size - children.reduce(0) { $0 + $1.size }) }

    func addChild(_ node: ScanNode) {
        node.parent = self
        children.append(node)
    }

    func sortChildrenBySize() {
        children.sort { $0.size > $1.size }
        children.forEach { $0.sortChildrenBySize() }
    }

    /// Finds the node for an absolute path inside this tree, if it was kept.
    func node(atPath target: String) -> ScanNode? {
        let rootPath = path
        guard target == rootPath || target.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        var current = self
        let rest = target.dropFirst(rootPath.count).split(separator: "/")
        for component in rest {
            guard let next = current.children.first(where: { $0.name == component }) else { return nil }
            current = next
        }
        return current
    }
}
