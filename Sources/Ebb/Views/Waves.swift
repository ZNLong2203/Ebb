import AppKit
import SwiftUI

/// Gently rolling water, drawn as layered sine waves that slide sideways forever.
///
/// Each layer is a wave two wavelengths wider than needed, translated by one wavelength in a
/// repeating Core Animation, so the motion is seamless and costs the app no CPU per frame.
/// `level` (0…1) sets the waterline and animates smoothly when it changes.
struct WaveView: NSViewRepresentable {
    struct Layer {
        var color: NSColor
        var amplitude: CGFloat
        var wavelength: CGFloat
        /// Seconds to travel one wavelength; negative flows right-to-left.
        var period: CFTimeInterval
        /// Where the crests sit, as a fraction of the view's height; nil stacks layers near the top.
        var crest: CGFloat? = nil
    }

    var layers: [Layer]
    var level: CGFloat = 1

    func makeNSView(context: Context) -> WaveLayerView { WaveLayerView() }

    func updateNSView(_ view: WaveLayerView, context: Context) {
        view.configure(layers: layers, level: level)
    }
}

final class WaveLayerView: NSView {
    private let container = CALayer()
    private var shapes: [CAShapeLayer] = []
    private var layers: [WaveView.Layer] = []
    private var level: CGFloat = 1
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(layers: [WaveView.Layer], level: CGFloat) {
        let layersChanged = layers.count != self.layers.count
            || zip(layers, self.layers).contains { $0.color != $1.color || $0.amplitude != $1.amplitude || $0.period != $1.period }
        self.layers = layers
        if layersChanged {
            builtSize = .zero
            needsLayout = true
        }
        if level != self.level {
            self.level = level
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            positionContainer()
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize, bounds.width > 0, bounds.height > 0 else { return }
        builtSize = bounds.size
        rebuild()
    }

    private func positionContainer() {
        // The water body is as tall as the view; sliding it down lowers the waterline.
        container.frame = CGRect(x: 0, y: -(1 - level) * bounds.height, width: bounds.width, height: bounds.height)
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapes.forEach { $0.removeFromSuperlayer() }
        shapes = layers.enumerated().map { index, spec in
            let shape = CAShapeLayer()
            let width = bounds.width + spec.wavelength * 2
            let crest = spec.crest.map { bounds.height * $0 }
                ?? bounds.height - spec.amplitude * 2 - CGFloat(index) * spec.amplitude * 0.6
            shape.path = Self.wavePath(width: width, height: crest, amplitude: spec.amplitude, wavelength: spec.wavelength)
            shape.fillColor = spec.color.cgColor
            shape.frame = CGRect(x: -spec.wavelength, y: 0, width: width, height: bounds.height)

            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = spec.period >= 0 ? 0 : spec.wavelength
            slide.toValue = spec.period >= 0 ? spec.wavelength : 0
            slide.duration = abs(spec.period)
            slide.repeatCount = .infinity
            slide.timingFunction = CAMediaTimingFunction(name: .linear)
            shape.add(slide, forKey: "slide")
            container.addSublayer(shape)
            return shape
        }
        positionContainer()
        CATransaction.commit()
    }

    /// A filled sine wave whose crests sit at `height`, filled down to y = 0.
    private static func wavePath(width: CGFloat, height: CGFloat, amplitude: CGFloat, wavelength: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: height))
        var x: CGFloat = 0
        while x <= width {
            path.addLine(to: CGPoint(x: x, y: height + sin(x / wavelength * 2 * .pi) * amplitude))
            x += 4
        }
        path.addLine(to: CGPoint(x: width, y: 0))
        path.closeSubpath()
        return path
    }
}

/// Bubbles drifting up for a moment, to celebrate a cleanup. Core Animation emitter, no per-frame work.
struct BubblesView: NSViewRepresentable {
    var isActive: Bool

    func makeNSView(context: Context) -> BubblesLayerView { BubblesLayerView() }

    func updateNSView(_ view: BubblesLayerView, context: Context) { view.setActive(isActive) }
}

final class BubblesLayerView: NSView {
    private let emitter = CAEmitterLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        emitter.emitterShape = .line
        emitter.renderMode = .additive
        emitter.birthRate = 0
        let cell = CAEmitterCell()
        cell.contents = Self.bubbleImage
        cell.birthRate = 14
        cell.lifetime = 4
        cell.velocity = 70
        cell.velocityRange = 40
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 8
        cell.xAcceleration = 0
        cell.yAcceleration = 10
        cell.scale = 0.35
        cell.scaleRange = 0.25
        cell.alphaSpeed = -0.22
        emitter.emitterCells = [cell]
        layer?.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: -10)
        emitter.emitterSize = CGSize(width: bounds.width, height: 1)
    }

    func setActive(_ active: Bool) {
        emitter.birthRate = active ? 1 : 0
        if active {
            emitter.beginTime = CACurrentMediaTime()
            // A burst, not a fountain: stop spawning after a couple of seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.emitter.birthRate = 0 }
        }
    }

    private static let bubbleImage: CGImage? = {
        let size = 40
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 3, y: 3, width: size - 6, height: size - 6)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: rect)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: size / 2 - 2, y: size / 2 + 4, width: 7, height: 7))
        return ctx.makeImage()
    }()
}

/// The scanning gauge: a porthole that fills with water as the scan measures more data.
struct TideGauge: View {
    let fraction: Double
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.06))
            WaveView(layers: [
                .init(color: NSColor(Tide.lagoon).withAlphaComponent(0.55), amplitude: 10, wavelength: 150, period: 3.2),
                .init(color: NSColor(Tide.foam).withAlphaComponent(0.85), amplitude: 7, wavelength: 115, period: -2.4),
            ], level: CGFloat(min(max(fraction, 0.06), 0.97)))
            .clipShape(Circle())
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 3)
            VStack(spacing: 4) {
                Text(title).font(.rounded(34, .bold)).monospacedDigit()
                Text(subtitle).font(.callout.weight(.medium)).opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .frame(width: 240, height: 240)
    }
}
