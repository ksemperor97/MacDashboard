import SwiftUI

enum Palette {
    static let user = Color.blue
    static let system = Color.red
    static let renderer = Color.purple
    static let tiler = Color.pink
    static let app = Color.blue
    static let wired = Color.orange
    static let compressed = Color.red
    static let disk = Color.indigo
    static let external = Color.cyan
    static let read = Color.green
    static let write = Color.orange
    static let down = Color.blue
    static let up = Color.red

    static func level(_ fraction: Double) -> Color {
        fraction < 0.5 ? .green : (fraction < 0.8 ? .orange : .red)
    }

    static func pressure(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct Card<Content: View>: View {
    var highlight: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlight?.opacity(0.7) ?? Color.primary.opacity(0.06), lineWidth: highlight == nil ? 0.5 : 1)
            }
    }
}

struct CardHeader<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            trailing
        }
    }
}

struct BigValue: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold).monospacedDigit())
            .contentTransition(.numericText())
    }
}

struct TempChip: View {
    let value: Double?
    var body: some View {
        if let value {
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium").font(.system(size: 9, weight: .semibold))
                Text(Format.temperature(value)).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: Capsule())
        }
    }
}

struct LegendItem: View {
    let color: Color?
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

struct ProgressBar: View {
    let fraction: Double?
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction ?? 0, 0), 1), (fraction ?? 0) > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

struct StackedBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.color).frame(width: max(geo.size.width * seg.fraction - 1, 0))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
    }
}

/// Line + soft area chart. Values are scaled to `maxValue` (or the series max, with a floor).
struct Sparkline: View {
    let series: [(values: [Double], color: Color)]
    var maxValue: Double?
    var floor: Double = 1
    var capacity = AppModel.historyLength

    var body: some View {
        Canvas { ctx, size in
            let peak = maxValue ?? max(series.flatMap(\.values).max() ?? 0, floor)
            guard peak > 0 else { return }
            // Faint guide lines like Activity Monitor.
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: y))
                guide.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(guide, with: .color(.primary.opacity(0.06)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            for s in series where s.values.count > 1 {
                let step = size.width / CGFloat(max(capacity - 1, 1))
                let start = size.width - step * CGFloat(s.values.count - 1)
                let points = s.values.enumerated().map { i, v in
                    CGPoint(x: start + step * CGFloat(i), y: size.height - size.height * CGFloat(min(v / peak, 1)))
                }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(0.28), s.color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
        }
    }
}

/// Small per-core bars (CPU card).
struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.user.opacity(0.75))
                        .frame(height: max(14 * min(v, 1), v > 0.01 ? 1.5 : 0))
                }
                .frame(height: 14)
            }
        }
        .animation(.easeOut(duration: 0.3), value: cores)
    }
}

struct FooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
