import AppKit
import SwiftUI

/// Local AI popover: loaded model, measured speed, benchmarks, and the resources that limit speed.
struct LocalAIView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.language) private var language = AppLanguage.system.rawValue
    let monitor: LocalAIMonitor
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            if let status = monitor.status {
                if status.models.isEmpty {
                    Card { Text(L.t("\(status.kind.displayName)가 실행 중이지만 로드된 모델이 없어요.",
                                    "\(status.kind.displayName) is running but no model is loaded."))
                        .font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                ForEach(status.models) { m in
                    // The log stream knows about a running request before `lms ps` does.
                    ModelCard(model: monitor.isWorking ? { var w = m; w.state = "generating"; return w }() : m)
                }
                speedCard
                benchmarkCard
                resourceCard
                if !monitor.samples.isEmpty { recentCard }
                if monitor.comparison.count > 1 { comparisonCard }
            } else {
                notRunningCard
            }
            footer
        }
        .padding(14)
        .frame(width: 460)
        .id(language)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu.fill").foregroundStyle(.purple)
            Text(L.t("로컬 AI", "Local AI")).font(.system(size: 15, weight: .bold))
            if let status = monitor.status {
                Text(status.kind.displayName + (status.version.map { " \($0)" } ?? ""))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Speed

    private var speedCard: some View {
        let latest = monitor.latest
        return Card {
            CardHeader(icon: "speedometer", title: L.t("속도", "Speed")) {
                if let latest {
                    Text(latest.source == .benchmark ? L.t("측정", "Benchmark") : L.t("다른 앱 요청", "App request"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(Format.clock(latest.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let latest {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.speed(latest.generationTokensPerSecond))
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    Text(L.t("토큰/초 생성", "tok/s generation")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Sparkline(series: [(monitor.currentModelSamples.suffix(30).compactMap(\.generationTokensPerSecond), .purple)], floor: 1,
                              capacity: 30)
                        .frame(width: 140, height: 34)
                }
                Grid(horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        LegendItem(color: nil, label: L.t("첫 토큰까지", "Time to first token"), value: Format.seconds(latest.timeToFirstToken))
                        LegendItem(color: nil, label: L.t("입력 처리", "Prompt processing"),
                                   value: Format.speed(latest.promptTokensPerSecond) + " tok/s")
                    }
                    GridRow {
                        LegendItem(color: nil, label: L.t("입력 / 출력", "In / out"),
                                   value: "\(Format.tokens(latest.promptTokens)) / \(Format.tokens(latest.completionTokens))")
                        LegendItem(color: nil, label: L.t("총 시간", "Total"), value: Format.seconds(latest.totalSeconds))
                    }
                }
            } else {
                Text(L.t("현재 모델의 측정 기록이 없어요. 아래에서 측정하거나 LM Studio로 요청을 보내면 여기 표시돼요.",
                         "No measurements for this model yet. Run a benchmark below, or send a request to LM Studio from any app."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Benchmark

    private var benchmarkCard: some View {
        Card {
            CardHeader(icon: "gauge.with.dots.needle.67percent", title: L.t("속도 측정", "Benchmark")) { EmptyView() }
            if let progress = monitor.benchmark {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.step), total: Double(progress.total)).frame(width: 120)
                    Text(progress.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L.t("취소", "Cancel")) { monitor.cancelBenchmark() }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button(L.t("빠른 측정", "Quick test")) { monitor.runBenchmark(sweep: false) }
                    Button(L.t("컨텍스트별 측정", "Context sweep")) { monitor.runBenchmark(sweep: true) }
                    Spacer()
                }
                .controlSize(.small)
                .disabled(monitor.activeModel == nil)
                Text(L.t("짧은 프롬프트, 또는 입력 약 1k·8k·32k 토큰으로 128토큰을 생성해 측정해요. 로컬 계산만 써요.",
                         "Generates 128 tokens from a short prompt, or from ~1k, 8k and 32k-token inputs. Local compute only."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
            }
            let run = monitor.latestRun
            if !run.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text(L.t("입력 토큰", "Input")).gridColumnAlignment(.leading)
                        Text(L.t("첫 토큰", "TTFT"))
                        Text(L.t("입력 처리", "Prompt"))
                        Text(L.t("생성", "Generation"))
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(run) { s in
                        GridRow {
                            Text(Format.tokens(s.promptTokens)).gridColumnAlignment(.leading)
                            Text(Format.seconds(s.timeToFirstToken))
                            Text(Format.speed(s.promptTokensPerSecond) + " tok/s")
                            Text(Format.speed(s.generationTokensPerSecond) + " tok/s").fontWeight(.semibold)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
            }
        }
    }

    // MARK: Resources

    private var resourceCard: some View {
        let s = model.snapshot
        let mem = s.memory
        let modelBytes = monitor.status?.models.compactMap(\.sizeBytes).reduce(0, +) ?? 0
        // Swap stays allocated long after a spike, so only live memory pressure counts as a warning.
        let warn = mem.pressure != .normal
        return Card {
            CardHeader(icon: "memorychip", title: L.t("리소스", "Resources")) { EmptyView() }
            if warn {
                Label(L.t("메모리 압력 \(mem.pressure.label). 모델이 스왑으로 밀려나면 속도가 크게 떨어져요. 다른 앱을 닫거나 더 작은 양자화·짧은 컨텍스트를 고려하세요.",
                          "Memory pressure is \(mem.pressure.label). If the model spills into swap, speed drops sharply. Close other apps or try a smaller quantization or shorter context."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    LegendItem(color: nil, label: "GPU", value: Format.percent(s.gpu.device))
                    LegendItem(color: nil, label: L.t("GPU 온도", "GPU temp"), value: Format.temperature(model.sensors.gpuTemp))
                }
                GridRow {
                    LegendItem(color: Palette.pressure(mem.pressure), label: L.t("메모리", "Memory"),
                               value: "\(Format.memory(mem.used)) / \(Format.memory(mem.total))")
                    LegendItem(color: nil, label: L.t("스왑", "Swap"), value: Format.memory(mem.swapUsed))
                }
                GridRow {
                    LegendItem(color: nil, label: L.t("모델 크기", "Model size"),
                               value: modelBytes > 0 ? Format.bytes(modelBytes, decimals: 1) : "–")
                    LegendItem(color: nil, label: L.t("시스템 전력", "System power"),
                               value: model.sensors.systemPower.map { String(format: "%.1f W", $0) } ?? "–")
                }
            }
        }
    }

    // MARK: History

    private var recentCard: some View {
        Card {
            CardHeader(icon: "clock.arrow.circlepath", title: L.t("최근 요청", "Recent requests")) {
                Button(L.t("기록 지우기", "Clear")) { monitor.clearHistory() }
                    .buttonStyle(.link).font(.system(size: 10))
            }
            ForEach(monitor.samples.suffix(6).reversed()) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.source == .benchmark ? "gauge.with.dots.needle.67percent" : "eye")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                    Text(Format.clock(s.date)).foregroundStyle(.secondary)
                    Text(s.model).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(Format.tokens(s.promptTokens))→\(Format.tokens(s.completionTokens))").foregroundStyle(.secondary)
                    Text(Format.speed(s.generationTokensPerSecond) + " tok/s").fontWeight(.semibold)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
    }

    private var comparisonCard: some View {
        Card {
            CardHeader(icon: "chart.bar.xaxis", title: L.t("모델 비교 (짧은 프롬프트 최고 기록)", "Model comparison (best short-prompt run)")) { EmptyView() }
            ForEach(Array(monitor.comparison.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.model).lineLimit(1).truncationMode(.middle)
                    if let q = row.quantization { Text(q).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(L.t("입력 ", "prompt ") + Format.speed(row.prompt)).foregroundStyle(.secondary)
                    Text(Format.speed(row.generation) + " tok/s").fontWeight(.semibold)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
    }

    private var notRunningCard: some View {
        Card {
            Text(L.t("실행 중인 로컬 AI 서버를 찾지 못했어요.", "No local AI server is running."))
                .font(.system(size: 12, weight: .semibold))
            Text(L.t("LM Studio(1234), Ollama(11434), llama.cpp 서버(8080)를 기본 포트에서 자동으로 찾아요. 서버를 켜면 몇 초 안에 표시돼요.",
                     "MacDashboard looks for LM Studio (1234), Ollama (11434) and llama.cpp server (8080) on their default ports. Start a server and it shows up within seconds."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            FooterButton(icon: "gearshape", title: L.t("설정…", "Settings…"), action: openSettings)
            Spacer()
            FooterButton(icon: "power", title: L.t("종료", "Quit")) { NSApp.terminate(nil) }
        }
    }
}

private struct ModelCard: View {
    let model: LocalModel

    var body: some View {
        Card {
            CardHeader(icon: "cube.transparent", title: model.name) {
                if let state = model.state {
                    Text(stateLabel(state))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((state == "generating" ? Color.green : Color.secondary).opacity(0.18), in: Capsule())
                        .foregroundStyle(state == "generating" ? .green : .secondary)
                }
            }
            let chips = [model.format, model.quantization, model.architecture, model.parameters].compactMap { $0 }
            if !chips.isEmpty {
                Text(chips.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    LegendItem(color: nil, label: L.t("컨텍스트", "Context"), value: contextText)
                    LegendItem(color: nil, label: L.t("크기", "Size"), value: model.sizeBytes.map { Format.bytes($0, decimals: 1) } ?? "–")
                }
                GridRow {
                    LegendItem(color: nil, label: L.t("병렬 요청", "Parallel"), value: model.parallel.map(String.init) ?? "–")
                    LegendItem(color: nil, label: L.t("자동 언로드", "Auto-unload"),
                               value: model.expiresAt.map { L.t("\(Format.duration($0.timeIntervalSinceNow)) 후", "in \(Format.duration($0.timeIntervalSinceNow))") } ?? L.t("없음", "Off"))
                }
            }
        }
    }

    private var contextText: String {
        guard let ctx = model.contextLength else { return "–" }
        guard let max = model.maxContextLength else { return Format.tokens(ctx) }
        return "\(Format.tokens(ctx)) / \(Format.tokens(max))"
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "generating": L.t("생성 중", "Generating")
        case "loading": L.t("불러오는 중", "Loading")
        case "idle": L.t("대기", "Idle")
        case "loaded": L.t("로드됨 · 활동 상태 확인 불가", "Loaded · activity unknown")
        case "unknown": L.t("활동 상태 확인 불가", "Activity unknown")
        default: state
        }
    }
}
