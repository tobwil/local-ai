import Charts
import SwiftUI

/// Veröffentlichte Benchmark-Werte: lokale Modelle (Herstellerangaben) gegen aktuelle Frontier-Modelle.
/// Stand 25.10.2026. Harnesses unterscheiden sich, die Werte sind nur grob vergleichbar.
enum BenchmarkData {
    struct Score: Identifiable {
        let model: String
        let group: Group
        let value: Double
        var id: String { model }
    }

    enum Group: String, Plottable {
        case local = "Lokal auf diesem Mac"
        case openFrontier = "Offen, Rechenzentrum"
        case frontier = "Frontier (Cloud)"
    }

    struct Benchmark: Identifiable {
        let name: String
        let what: String
        let scores: [Score]
        var id: String { name }
    }

    static let all: [Benchmark] = [
        Benchmark(name: "SWE-bench Verified", what: "Echte GitHub-Issues lösen (Coding-Agent)", scores: [
            Score(model: "GPT-5.6 Sol", group: .frontier, value: 96.2),
            Score(model: "Claude Opus 5", group: .frontier, value: 96.0),
            Score(model: "Claude Mythos 5", group: .frontier, value: 95.5),
            Score(model: "Claude Fable 5", group: .frontier, value: 95.0),
            Score(model: "Ornith 1.5 397B", group: .openFrontier, value: 86.0),
            Score(model: "Claude Sonnet 5", group: .frontier, value: 85.2),
            Score(model: "GPT-5.5", group: .frontier, value: 80.6),
            Score(model: "Ornith 1.5 35B", group: .local, value: 79.0),
            Score(model: "Flint 40B", group: .local, value: 74.2),
            Score(model: "Qwen 3.6 35B", group: .local, value: 73.4),
            Score(model: "Mellum 2.1 12B", group: .local, value: 47.0),
        ]),
        Benchmark(name: "SWE-bench Pro", what: "Schwerere, längere Software-Aufgaben", scores: [
            Score(model: "Claude Opus 5.5", group: .frontier, value: 89.9),
            Score(model: "Claude Sonnet 5.5", group: .frontier, value: 81.3),
            Score(model: "Claude Fable 5", group: .frontier, value: 80.0),
            Score(model: "Qwen 3.8 Max", group: .openFrontier, value: 67.7),
            Score(model: "Claude Haiku 5.5", group: .frontier, value: 64.8),
            Score(model: "GPT-5.6 Sol", group: .frontier, value: 64.6),
            Score(model: "Qwen 3.8 27B", group: .openFrontier, value: 61.7),
            Score(model: "Ornith 1.5 35B", group: .local, value: 59.6),
            Score(model: "GPT-5.5", group: .frontier, value: 58.6),
            Score(model: "Qwen 3.6 35B", group: .local, value: 49.5),
            Score(model: "Mellum 2.1 12B", group: .local, value: 28.0),
        ]),
        Benchmark(name: "Terminal-Bench 2.x", what: "Aufgaben im Terminal (Versionen 2.0/2.1 gemischt)", scores: [
            Score(model: "Claude Opus 5.5", group: .frontier, value: 87.6),
            Score(model: "GPT-5.5", group: .frontier, value: 82.7),
            Score(model: "Claude Opus 4.7", group: .frontier, value: 69.4),
            Score(model: "DeepSeek V4 Pro", group: .openFrontier, value: 67.9),
            Score(model: "Ornith 1.5 35B", group: .local, value: 67.8),
            Score(model: "Flint 40B", group: .local, value: 54.9),
            Score(model: "Qwen 3.6 35B", group: .local, value: 52.5),
            Score(model: "Mellum 2.1 12B", group: .local, value: 17.4),
        ]),
        Benchmark(name: "GPQA Diamond", what: "Fachfragen auf Doktorats-Niveau", scores: [
            Score(model: "GPT-6 Astra", group: .frontier, value: 96.0),
            Score(model: "GPT-5.6 Sol", group: .frontier, value: 94.6),
            Score(model: "Gemini 3.1 Pro", group: .frontier, value: 94.3),
            Score(model: "Claude Fable 5.1", group: .frontier, value: 93.7),
            Score(model: "GPT-5.5", group: .frontier, value: 93.6),
            Score(model: "Ornith 1.5 35B", group: .local, value: 89.2),
            Score(model: "Qwen 3.6 35B", group: .local, value: 86.0),
            Score(model: "Gemma 4 26B", group: .local, value: 82.3),
            Score(model: "Mellum 2.1 12B", group: .local, value: 64.6),
        ]),
        Benchmark(name: "Humanity's Last Exam", what: "Extrem schwere Wissensfragen (teils mit, teils ohne Werkzeuge)", scores: [
            Score(model: "Claude Fable 5.1", group: .frontier, value: 65.0),
            Score(model: "Claude Opus 5", group: .frontier, value: 64.7),
            Score(model: "Claude Mythos 5", group: .frontier, value: 64.5),
            Score(model: "GPT-6 Astra", group: .frontier, value: 55.0),
            Score(model: "GPT-6.1 Sol", group: .frontier, value: 53.0),
            Score(model: "GPT-5.5", group: .frontier, value: 41.4),
            Score(model: "Ornith 1.5 35B", group: .local, value: 25.6),
            Score(model: "Qwen 3.6 35B", group: .local, value: 21.4),
        ]),
        Benchmark(name: "ARC-AGI-2", what: "Neue Denkaufgaben, die man nicht auswendig lernen kann (für lokale Modelle keine Werte)", scores: [
            Score(model: "GPT-6 Astra (Max)", group: .frontier, value: 95.0),
            Score(model: "GPT-6.1 Sol (Max)", group: .frontier, value: 94.2),
            Score(model: "Claude Opus 5.5 (High)", group: .frontier, value: 93.3),
            Score(model: "GPT-5.6 Sol (Max)", group: .frontier, value: 92.5),
        ]),
    ]

    static let sources: [(String, String)] = [
        ("Ornith 1.5 35B Model Card", "https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B"),
        ("Flint Model Card", "https://huggingface.co/RecursiveSI/flint"),
        ("Mellum 2.1 Model Card", "https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking"),
        ("OpenAI: Introducing GPT-5.5", "https://openai.com/index/introducing-gpt-5-5/"),
        ("LLM-Stats: SWE-Bench Pro", "https://llm-stats.com/benchmarks/swe-bench-pro"),
        ("BenchLM Top-10 (Spiegel)", "https://github.com/leoncuhk/awesome-llm-bench"),
        ("LM Council Benchmarks", "https://lmcouncil.ai/benchmarks"),
        ("Vellum: GPT-6 Astra Benchmarks", "https://www.vellum.ai/blog/gpt-6-astra-benchmarks-explained"),
        ("Artificial Analysis: GPT-6.1 Sol vs. GPT-6 Astra", "https://artificialanalysis.ai/models/comparisons/gpt-6-1-sol-vs-gpt-6-astra"),
        ("Vals.ai: Claude Opus 5.5", "https://www.vals.ai/models/anthropic_claude-opus-5-5"),
        ("BenchLM: Claude Opus 5.5", "https://benchlm.ai/models/claude-opus-5-5"),
        ("LLM-Stats: SWE-bench Verified", "https://llm-stats.com/benchmarks/swe-bench-verified"),
        ("regolo.ai: Qwen 3.6 vs. Gemma 4", "https://regolo.ai/?p=3417"),
    ]
}

struct CompareView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Text("Wie gut ist lokal?").font(.title2.bold())
                    Text("Die Spitze (GPT-6 Astra, GPT-6.1 Sol, Claude Opus 5.5, Fable 5.1) ist bei schwerem Denken und Wissen klar vorn – das sind Rechenzentrums-Modelle. Ornith 1.5 35B auf deinem Mac (gold) erreicht beim Coden etwa GPT-5.5 (SWE-bench Verified 79 vs. 80,6; SWE-bench Pro 59,6 vs. 58,6), bei GPQA liegt es rund 4 Punkte dahinter – dafür kostenlos, privat und offline.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        legend(.local, Theme.gold)
                        legend(.openFrontier, Theme.sky)
                        legend(.frontier, .gray)
                    }
                    .font(.caption)
                }
                ForEach(BenchmarkData.all) { bench in
                    Card {
                        HStack(alignment: .firstTextBaseline) {
                            Text(bench.name).font(.headline)
                            Text(bench.what).font(.caption).foregroundStyle(.secondary)
                        }
                        CompareChart(bench: bench)
                    }
                }
                Card {
                    Text("Quellen & Hinweise").font(.headline)
                    Text("Herstellerangaben und öffentliche Leaderboards, Stand 25.10.2026. Unterschiedliche Test-Setups (Harness, Werkzeuge, Versionen 2.0/2.1) – die Werte zeigen Größenordnungen, keine exakte Rangfolge. Die lokalen Modelle laufen hier quantisiert (3–4 Bit) und können etwas schlechter abschneiden als in den Herstellerzahlen.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(BenchmarkData.sources, id: \.1) { name, url in
                        Link(name, destination: URL(string: url)!).font(.caption)
                    }
                }
            }
            .padding(24)
        }
    }

    private func legend(_ g: BenchmarkData.Group, _ c: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 12, height: 12)
            Text(g.rawValue)
        }
    }
}


struct CompareChart: View {
    let bench: BenchmarkData.Benchmark
    var body: some View {
        Chart(bench.scores.sorted { $0.value > $1.value }) { s in
            BarMark(x: .value("Punkte", s.value), y: .value("Modell", s.model))
                .foregroundStyle(by: .value("Gruppe", s.group))
                .annotation(position: .trailing) {
                    Text(String(format: "%.1f", s.value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
        }
        .chartForegroundStyleScale([BenchmarkData.Group.local: Theme.gold,
                                    BenchmarkData.Group.openFrontier: Theme.sky,
                                    BenchmarkData.Group.frontier: Color.gray])
        .chartLegend(.hidden)
        .chartXScale(domain: 0...100)
        .frame(height: CGFloat(bench.scores.count) * 26 + 20)
    }
}
