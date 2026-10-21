import SwiftUI

struct DiskMapView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let root = model.result?.root {
            let focus = model.mapFocus ?? root
            VStack(spacing: 0) {
                breadcrumb(focus: focus, root: root)
                GeometryReader { geo in
                    TreemapCanvas(cells: Treemap.layout(focus, in: CGRect(origin: .zero, size: geo.size)), model: model)
                }
                .padding(12)
            }
        }
    }

    private func breadcrumb(focus: ScanNode, root: ScanNode) -> some View {
        var chain: [ScanNode] = []
        var node: ScanNode? = focus
        while let current = node {
            chain.insert(current, at: 0)
            node = current === root ? nil : current.parent
        }
        return HStack(spacing: 4) {
            Button { model.mapFocus = focus.parent.flatMap { focus === root ? nil : $0 } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(focus === root)
            ForEach(Array(chain.enumerated()), id: \.offset) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(index == 0 ? (node.name as NSString).abbreviatingWithTildeInPath : node.name) {
                    model.mapFocus = node === root ? nil : node
                }
                .buttonStyle(.plain)
                .fontWeight(node === focus ? .semibold : .regular)
            }
            Spacer()
            Text(focus.size.bytes).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct TreemapCell {
    let node: ScanNode?
    let rect: CGRect
    let depth: Int
    let color: Color
    let title: String
    let size: Int64
    /// Depth-0 folders with their children drawn inside get a header strip for the label.
    let hasChildren: Bool
}

enum Treemap {
    /// Sea-glass palette, one colour per top-level block.
    static let palette: [Color] = [
        Color(red: 0.11, green: 0.42, blue: 0.72), Color(red: 0.13, green: 0.62, blue: 0.70),
        Color(red: 0.27, green: 0.66, blue: 0.52), Color(red: 0.86, green: 0.60, blue: 0.33),
        Color(red: 0.78, green: 0.39, blue: 0.42), Color(red: 0.47, green: 0.42, blue: 0.75),
        Color(red: 0.33, green: 0.52, blue: 0.62), Color(red: 0.62, green: 0.55, blue: 0.40),
    ]

    private struct Entry {
        let node: ScanNode?
        let name: String
        let size: Int64
    }

    static func layout(_ focus: ScanNode, in bounds: CGRect) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        let top = entries(for: focus, limit: 120)
        for (index, (entry, rect)) in zip(top, squarify(top.map { Double($0.size) }, in: bounds)).enumerated() {
            let color = entry.node == nil ? Color.gray.opacity(0.55) : palette[index % palette.count]
            let nested = entry.node.map { $0.isDirectory && !$0.children.isEmpty } ?? false
            let showsChildren = nested && rect.width > 90 && rect.height > 64
            cells.append(TreemapCell(node: entry.node, rect: rect, depth: 0, color: color, title: entry.name,
                                     size: entry.size, hasChildren: showsChildren))
            guard showsChildren, let node = entry.node else { continue }
            let inner = CGRect(x: rect.minX + 3, y: rect.minY + 20, width: rect.width - 6, height: rect.height - 23)
            let sub = entries(for: node, limit: 60)
            for (subIndex, (child, childRect)) in zip(sub, squarify(sub.map { Double($0.size) }, in: inner)).enumerated() {
                let shade = child.node == nil ? Color.black.opacity(0.25) : lighter(color, by: subIndex.isMultiple(of: 2) ? 0.12 : 0.24)
                cells.append(TreemapCell(node: child.node, rect: childRect, depth: 1, color: shade, title: child.name,
                                         size: child.size, hasChildren: false))
            }
        }
        return cells
    }

    /// `Color.mix` needs macOS 15; NSColor blending works on 14.
    private static func lighter(_ color: Color, by fraction: CGFloat) -> Color {
        Color(nsColor: NSColor(color).blended(withFraction: fraction, of: .white) ?? NSColor(color))
    }

    private static func entries(for node: ScanNode, limit: Int) -> [Entry] {
        var entries = node.children.prefix(limit).filter { $0.size > 0 }.map { Entry(node: $0, name: $0.name, size: $0.size) }
        let rest = node.size - entries.reduce(0) { $0 + $1.size }
        if rest > max(node.size / 200, 1) { entries.append(Entry(node: nil, name: "Other files", size: rest)) }
        return entries
    }

    /// Bruls et al.'s squarified treemap: fills rows along the shorter side while it keeps
    /// rectangles close to square. Values must be sorted largest first.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var start = 0

        func worst(_ range: Range<Int>, _ sum: Double, _ side: Double) -> Double {
            let slice = areas[range]
            guard let largest = slice.max(), let smallest = slice.min(), smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), (sum * sum) / (side * side * smallest))
        }

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var sum = areas[start]
            while end < areas.count, worst(start..<(end + 1), sum + areas[end], side) <= worst(start..<end, sum, side) {
                sum += areas[end]
                end += 1
            }
            let thickness = CGFloat(sum / side)
            var offset: CGFloat = 0
            let alongHeight = remaining.width >= remaining.height
            for index in start..<end {
                let length = CGFloat(areas[index]) / thickness
                result[index] = alongHeight
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            remaining = alongHeight
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness, height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: remaining.height - thickness)
            start = end
        }
        return result
    }
}

private struct TreemapCanvas: View {
    let cells: [TreemapCell]
    let model: AppModel

    @ViewState private var hovered: Int?
    @ViewState private var pendingTrash: ScanNode?

    var body: some View {
        Canvas { context, _ in
            for (index, cell) in cells.enumerated() {
                let rect = cell.rect.insetBy(dx: 1, dy: 1)
                guard rect.width > 1, rect.height > 1 else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: cell.depth == 0 ? 7 : 4, style: .continuous)
                context.fill(shape, with: .color(cell.color))
                if index == hovered {
                    context.fill(shape, with: .color(.white.opacity(0.18)))
                    context.stroke(shape, with: .color(.white), lineWidth: 2)
                }
                drawLabel(cell, in: rect, context: context)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = cells.lastIndex { $0.rect.contains(point) }
            case .ended: hovered = nil
            }
        }
        .onTapGesture { location in
            guard let index = cells.lastIndex(where: { $0.rect.contains(location) }) else { return }
            // Zoom into the clicked folder; clicking a nested block zooms into it directly.
            if let node = cells[index].node, node.isDirectory, !node.children.isEmpty {
                model.mapFocus = node
            }
        }
        .contextMenu {
            if let index = hovered, let node = cells[index].node {
                Button("Show in Finder") { model.reveal(node.path) }
                if node.isDirectory, !node.children.isEmpty {
                    Button("Zoom In") { model.mapFocus = node }
                }
                Divider()
                Button("Move to Trash…") { pendingTrash = node }
                    .disabled(model.protection(for: node.path) != nil || model.isScanning)
            }
        }
        .overlay(alignment: .bottomLeading) { hoverInfo }
        .confirmationDialog("Move \(pendingTrash?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                guard let node = pendingTrash else { return }
                Task { _ = await model.trash(paths: [node.path], sizes: [node.size]) }
            }
        } message: {
            Text("\(pendingTrash?.size.bytes ?? ""). You can put it back from the Trash until you empty it.")
        }
    }

    private func drawLabel(_ cell: TreemapCell, in rect: CGRect, context: GraphicsContext) {
        let minWidth: CGFloat = cell.depth == 0 ? 54 : 64
        guard rect.width > minWidth, rect.height > (cell.hasChildren ? 18 : 30) else { return }
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 4, dy: 2)))
        let name = Text(cell.title).font(.system(size: cell.depth == 0 ? 12 : 11, weight: .semibold)).foregroundColor(.white)
        let size = Text(cell.size.bytes).font(.system(size: 10.5).monospacedDigit()).foregroundColor(.white.opacity(0.8))
        if cell.hasChildren {
            clipped.draw(name + Text("  ") + size, at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), anchor: .topLeading)
        } else {
            clipped.draw(name, at: CGPoint(x: rect.minX + 6, y: rect.minY + 5), anchor: .topLeading)
            clipped.draw(size, at: CGPoint(x: rect.minX + 6, y: rect.minY + 20), anchor: .topLeading)
        }
    }

    @ViewBuilder private var hoverInfo: some View {
        if let index = hovered, index < cells.count {
            let cell = cells[index]
            HStack(spacing: 8) {
                Image(systemName: cell.node?.isDirectory == true ? "folder.fill" : "doc.fill")
                Text(cell.node.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Files too small to draw individually")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(cell.size.bytes).monospacedDigit().fontWeight(.semibold)
                if let node = cell.node, node.isDirectory, !node.children.isEmpty {
                    Text("Click to zoom in").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
            .allowsHitTesting(false)
        }
    }
}
