import NEBULACore
import NEBULADesignSystem
import SwiftUI

/// NEBULA's redacted diagnostics bundle as a readable summary (health, providers, host, recent events, log errors)
/// with a collapsible raw view of every file. Unpacked in memory only; nothing is saved on this device.
struct DiagnosticsView: View {
    let store: SystemStore

    var body: some View {
        Group {
            switch store.diagnosticsPhase {
            case .idle, .loading:
                if let r = store.diagnostics { report(r) } else { loading }
            case .failed(let msg):
                if let r = store.diagnostics {
                    report(r)
                } else {
                    ContentUnavailableView {
                        Label("Could not load diagnostics", systemImage: "stethoscope")
                    } description: {
                        Text(msg)
                    } actions: {
                        Button("Try again") { Task { await store.loadDiagnostics() } }.buttonStyle(.borderedProminent)
                    }
                }
            case .loaded:
                if let r = store.diagnostics { report(r) } else { loading }
            }
        }
        .navigationTitle(Text("Diagnostics"))
        .systemInlineTitle()
        .task { if store.diagnostics == nil { await store.loadDiagnostics() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.busyAction == .diagnostics {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.loadDiagnostics() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.busyAction != nil)
                }
            }
        }
    }

    private var loading: some View {
        VStack(spacing: NSpace.m) {
            ProgressView()
            Text("Preparing diagnostics…").font(.callout).foregroundStyle(NColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func report(_ r: DiagnosticsReport) -> some View {
        Form {
            overview(r)
            if !r.providers.isEmpty || r.health?["providers"]?.object != nil { providers(r) }
            host(r)
            if r.eventTotal > 0 { events(r) }
            if !r.logs.isEmpty { logs(r) }
            raw(r)
        }
        .systemFormStyle()
    }

    // MARK: sections

    private func overview(_ r: DiagnosticsReport) -> some View {
        let h = r.health
        return Section {
            row(String(localized: "NEBULA status"), SText.health(h?["status"]?.string), ok: h?["status"]?.string == "ok")
            row(String(localized: "Database"), h?["db"]?.string == "ok" ? String(localized: "All good") : (h?["db"]?.string ?? "–"),
                ok: h?["db"]?.string == "ok")
            row(String(localized: "Ubuntu VM"), SText.vmState(h?["vm"]?["state"]?.string), ok: h?["vm"]?["state"]?.string == "running")
            let g = h?["guest"]
            row(String(localized: "Service in the VM"),
                SText.guest(g?["status"]?.string) + (g?["latency_ms"]?.double.map { " · " + SText.ms($0) } ?? ""),
                ok: g?["status"]?.string == "ok")
            if let polling = h?["telegram"]?["polling"]?.bool {
                row(String(localized: "Telegram"), polling ? String(localized: "Connected") : String(localized: "Not running"), ok: polling)
            }
            if let v = h?["version"]?.string {
                ValueRow(title: String(localized: "Version"), value: v)
            }
        } header: {
            Text("Overview")
        }
    }

    private func providers(_ r: DiagnosticsReport) -> some View {
        Section {
            if !r.providers.isEmpty {
                ForEach(Array(r.providers.enumerated()), id: \.offset) { _, p in
                    let state = p["state"]?.string ?? "–"
                    row(p["display_name"]?.string ?? p["id"]?.string ?? "?", state, ok: state.hasPrefix("Connected"))
                }
            } else if let map = r.health?["providers"]?.object {
                ForEach(map.keys.sorted(), id: \.self) { k in
                    let state = map[k]?.string ?? "–"
                    row(k, state, ok: state.hasPrefix("Connected"))
                }
            }
        } header: {
            Text("AI providers")
        }
    }

    @ViewBuilder
    private func host(_ r: DiagnosticsReport) -> some View {
        if let h = r.system?["host"] {
            Section {
                if let os = h["os"]?.string {
                    ValueRow(title: String(localized: "System"), value: [os, h["arch"]?.string].compactMap { $0 }.joined(separator: " · "))
                }
                if let free = h["memory_free_percent"]?.double {
                    ValueRow(title: String(localized: "Free memory"),
                             value: "\(SText.percent(free / 100)) · \(SText.pressure(h["memory_pressure"]?.string))")
                }
                if let d = h["disk_free_bytes"]?.double {
                    ValueRow(title: String(localized: "Free disk space"), value: NFormat.bytes(d))
                }
                if let st = r.system?["installation"]?["state"]?.string {
                    ValueRow(title: String(localized: "Installation"), value: st)
                }
            } header: {
                Text("Mac mini")
            }
        }
    }

    private func events(_ r: DiagnosticsReport) -> some View {
        Section {
            ValueRow(title: String(localized: "Events"), value: String(r.eventTotal))
            ValueRow(title: String(localized: "Failures"), value: String(r.failedEvents),
                     tint: r.failedEvents > 0 ? NColor.warning : nil)
            ForEach(r.eventCounts) { e in
                LabeledContent {
                    Text("\(e.count)").monospacedDigit().foregroundStyle(NColor.textSecondary)
                } label: {
                    Text(e.type).font(NFont.monoSmall)
                }
            }
        } header: {
            Text("Latest events")
        }
    }

    private func logs(_ r: DiagnosticsReport) -> some View {
        Section {
            ForEach(r.logs) { log in
                VStack(alignment: .leading, spacing: NSpace.xs) {
                    HStack {
                        Text(log.name).font(NFont.mono)
                        Spacer()
                        if log.errors > 0 { NBadge(String(localized: "\(log.errors) errors"), tint: NColor.danger) }
                        if log.warnings > 0 { NBadge(String(localized: "\(log.warnings) warnings"), tint: NColor.warning) }
                    }
                    Text("\(log.lines) lines").font(.caption).foregroundStyle(NColor.textTertiary)
                    ForEach(Array(log.lastErrors.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(NColor.danger)
                            .lineLimit(3).textSelection(.enabled)
                    }
                }
                .padding(.vertical, NSpace.xxs)
            }
        } header: {
            Text("Logs")
        } footer: {
            Text("The latest errors from each log. NEBULA removes passwords, tokens and keys from the diagnostics.")
        }
    }

    private func raw(_ r: DiagnosticsReport) -> some View {
        Section {
            ForEach(r.files) { f in
                RawFileRow(file: f)
            }
        } header: {
            Text("Raw data")
        } footer: {
            Text("Diagnostics are shown only on this device and are not stored anywhere.")
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value).foregroundStyle(NColor.textSecondary).multilineTextAlignment(.trailing)
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? NColor.success : NColor.warning)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One file of the bundle; its text is built only when expanded.
private struct RawFileRow: View {
    let file: DiagnosticsReport.File
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                ScrollView(.horizontal) {
                    Text(file.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(NColor.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.vertical, NSpace.xs)
                }
                HStack {
                    Spacer()
                    Button("Copy") {
                        copyToPasteboard(file.text)
                        Haptics.success()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        } label: {
            HStack {
                Text(file.name).font(NFont.monoSmall)
                Spacer()
                Text(NFormat.bytes(Double(file.bytes))).font(.caption).foregroundStyle(NColor.textTertiary)
            }
        }
    }
}

/// DiagnosticsView in its own sheet.
struct DiagnosticsSheet: View {
    let store: SystemStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DiagnosticsView(store: store)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 760)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }
}
