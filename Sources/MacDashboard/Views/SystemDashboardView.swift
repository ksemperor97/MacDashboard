import AppKit
import SwiftUI

struct SystemDashboardView: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                cpuCard
                gpuCard
            }
            .fixedSize(horizontal: false, vertical: true)
            memoryCard
            diskCard
            HStack(alignment: .top, spacing: 10) {
                networkCard
                fanCard
            }
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(14)
        .frame(width: 460)
    }

    private var s: SystemSnapshot { model.snapshot }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(.blue)
            Text("MacDashboard").font(.system(size: 15, weight: .bold))
            Spacer()
            if let boot = s.bootTime {
                Text("가동 \(Format.duration(Date().timeIntervalSince(boot)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private var cpuCard: some View {
        Card {
            CardHeader(icon: "cpu", title: "CPU") {
                TempChip(value: model.sensors.cpuTemp)
                BigValue(text: Format.percent(s.cpu.total))
            }
            Sparkline(series: [
                (zip(model.cpuUserHistory, model.cpuSystemHistory).map { $0 + $1 }, Palette.user),
                (model.cpuSystemHistory, Palette.system),
            ], maxValue: 1)
            .frame(height: 44)
            CoreBars(cores: s.cpu.cores)
            HStack(spacing: 10) {
                LegendItem(color: Palette.user, label: "사용자", value: Format.percent(s.cpu.user))
                LegendItem(color: Palette.system, label: "시스템", value: Format.percent(s.cpu.system))
            }
        }
    }

    private var gpuCard: some View {
        Card {
            CardHeader(icon: "square.stack.3d.up", title: "GPU") {
                TempChip(value: model.sensors.gpuTemp)
                BigValue(text: Format.percent(s.gpu.device))
            }
            Sparkline(series: [(model.gpuHistory, Palette.renderer)], maxValue: 1)
                .frame(height: 44)
            ProgressBar(fraction: s.gpu.device, color: Palette.renderer, height: 5)
                .padding(.vertical, 4.5)
            HStack(spacing: 10) {
                LegendItem(color: Palette.renderer, label: "렌더러", value: Format.percent(s.gpu.renderer))
                LegendItem(color: Palette.tiler, label: "타일러", value: Format.percent(s.gpu.tiler))
            }
        }
    }

    private var memoryCard: some View {
        let m = s.memory
        let total = Double(max(m.total, 1))
        return Card {
            CardHeader(icon: "memorychip", title: "메모리") {
                Text("\(Format.memory(m.used)) / \(Format.memory(m.total))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Circle().fill(Palette.pressure(m.pressure)).frame(width: 8, height: 8)
                BigValue(text: Format.percent(m.usedFraction))
            }
            StackedBar(segments: [
                (Double(m.app) / total, Palette.app),
                (Double(m.wired) / total, Palette.wired),
                (Double(m.compressed) / total, Palette.compressed),
            ])
            Grid(horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    LegendItem(color: Palette.app, label: "앱", value: Format.memory(m.app))
                    LegendItem(color: Palette.wired, label: "와이어드", value: Format.memory(m.wired))
                }
                GridRow {
                    LegendItem(color: Palette.compressed, label: "압축", value: Format.memory(m.compressed))
                    LegendItem(color: nil, label: "스왑", value: Format.memory(m.swapUsed))
                }
                GridRow {
                    LegendItem(color: Palette.pressure(m.pressure), label: "메모리 압력", value: m.pressure.label)
                    Color.clear.frame(height: 1)
                }
            }
        }
    }

    private var diskCard: some View {
        let d = s.disk
        return Card {
            CardHeader(icon: "internaldrive", title: "디스크") {
                BigValue(text: Format.percent(d.usedFraction))
            }
            ProgressBar(fraction: d.usedFraction, color: Palette.disk, height: 6)
            Text("\(Format.bytes(d.used, decimals: 2)) 사용 · \(Format.bytes(d.available, decimals: 2)) 남음 / \(Format.bytes(d.total, decimals: 2))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label(Format.rate(d.readRate), systemImage: "arrow.down.doc")
                    .foregroundStyle(Palette.read)
                Label(Format.rate(d.writeRate), systemImage: "arrow.up.doc")
                    .foregroundStyle(Palette.write)
                Spacer()
                Sparkline(series: [(model.diskReadHistory, Palette.read), (model.diskWriteHistory, Palette.write)],
                          floor: 1_000_000)
                    .frame(width: 90, height: 22)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            ForEach(model.externalVolumes) { volume in
                Divider().padding(.vertical, 2)
                ExternalVolumeRow(volume: volume)
            }
        }
    }

    private var networkCard: some View {
        let n = s.network
        return Card {
            CardHeader(icon: n.isWiFi ? "wifi" : "cable.connector.horizontal", title: n.kind) {
                if n.vpnActive {
                    Text("VPN")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            Sparkline(series: [(model.netDownHistory, Palette.down), (model.netUpHistory, Palette.up)], floor: 50_000)
                .frame(height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Label(Format.rate(n.downRate), systemImage: "arrow.down").foregroundStyle(Palette.down)
                Label(Format.rate(n.upRate), systemImage: "arrow.up").foregroundStyle(Palette.up)
            }
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(n.ipv4 ?? "연결 안 됨")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var fanCard: some View {
        let fans = model.sensors.fans
        let running = fans.contains { $0.rpm > 100 }
        return Card {
            CardHeader(icon: "fan", title: "팬") {
                Text(fans.isEmpty ? "없음" : (running ? "동작 중" : "정지"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if fans.isEmpty {
                Text("팬 센서를 찾지 못했어요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(fans) { fan in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "fan").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(fans.count == 2 ? (fan.id == 0 ? "왼쪽" : "오른쪽") : "팬 \(fan.id + 1)")
                            .font(.system(size: 11))
                        Spacer()
                        Text("\(Int(fan.rpm.rounded())) rpm").font(.system(size: 11).monospacedDigit())
                    }
                    ProgressBar(fraction: fan.fraction, color: .teal, height: 4)
                }
            }
            if let maxRPM = fans.first?.maxRPM, maxRPM > 0 {
                Text("범위 \(Int(fans.first!.minRPM))–\(Int(maxRPM)) rpm")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var footer: some View {
        HStack {
            FooterButton(icon: "gearshape", title: "설정", action: openSettings)
            Spacer()
            FooterButton(icon: "waveform.path.ecg", title: "활성 상태 보기") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
            FooterButton(icon: "power", title: "종료") { NSApp.terminate(nil) }
        }
        .foregroundStyle(.primary)
    }
}

private struct ExternalVolumeRow: View {
    let volume: ExternalVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(volume.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !volume.detail.isEmpty {
                    Text(volume.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(Format.percent(volume.usedFraction))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            ProgressBar(fraction: volume.usedFraction, color: Palette.external, height: 5)
            Text("\(Format.bytes(volume.used, decimals: 2)) 사용 · \(Format.bytes(volume.available, decimals: 2)) 남음 / \(Format.bytes(volume.total, decimals: 2))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
