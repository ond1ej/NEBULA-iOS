import NEBULACore
import NEBULADesignSystem
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Mac mini (memory, pressure, CPU, disk, NEBULA version), the Ubuntu VM (state, memory, Start / Stop), what is
/// running, connection latency and maintenance (backup, diagnostics, restart services). Every risky action asks first.
public struct SystemStatusView: View {
    let store: SystemStore

    @State private var banner: SBanner?
    @State private var stopCandidates: [SystemStore.RunningTask]?
    @State private var checkingTasks = false
    @State private var confirmRestart = false
    @State private var showDiagnostics = false

    public init(store: SystemStore) { self.store = store }

    public var body: some View {
        Group {
            if store.showsSkeleton {
                StatusSkeleton()
            } else if case .failed(let msg) = store.phase, store.health == nil, store.system == nil {
                ContentUnavailableView {
                    Label("Could not load the system status", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Try again") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
                }
            } else {
                content
            }
        }
        .navigationTitle(Text("System"))
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(Text("Refresh status (⌘R)"))
            }
        }
        #endif
        .systemBanner($banner)
    }

    private var content: some View {
        Form {
            if let err = store.refreshError {
                Section {
                    NBanner(err, style: .warning, symbol: "wifi.exclamationmark")
                        .listRowInsets(EdgeInsets(top: NSpace.s, leading: NSpace.s, bottom: NSpace.s, trailing: NSpace.s))
                }
            }
            macSection
            vmSection
            activitySection
            connectionSection
            maintenanceSection
        }
        .systemFormStyle()
        .refreshable { await store.refresh() }
        .confirmationDialog(Text("Stop the Ubuntu VM?"),
                            isPresented: Binding(get: { stopCandidates != nil }, set: { if !$0 { stopCandidates = nil } }),
                            titleVisibility: .visible, presenting: stopCandidates) { _ in
            Button("Stop VM", role: .destructive) {
                Task { banner = .from(await store.stopVM()) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { tasks in
            Text(stopMessage(tasks))
        }
        .confirmationDialog(Text("Restart NEBULA services?"), isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                Task { banner = .from(await store.restartServices()) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The NEBULA server on the Mac mini restarts and the connection drops for a few seconds. Agents, tasks and data are kept.")
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(store: store)
        }
    }

    // MARK: Mac mini

    private var macSection: some View {
        let host = store.system?.host
        return Section {
            if let used = store.memoryUsedFraction {
                HStack(spacing: NSpace.l) {
                    MemoryRing(fraction: used, tint: SText.pressureColor(host?.memoryPressure))
                    VStack(alignment: .leading, spacing: NSpace.xs) {
                        Text("Memory").font(NFont.headline)
                        if let total = host?.memoryTotalBytes {
                            let usedBytes = total - (host?.memoryAvailableBytes ?? total * (1 - used))
                            Text("\(NFormat.bytes(usedBytes)) of \(NFormat.bytes(total))")
                                .font(.callout).monospacedDigit().foregroundStyle(NColor.textSecondary)
                        }
                        HStack(spacing: NSpace.xs) {
                            Text("Pressure").font(.footnote).foregroundStyle(NColor.textSecondary)
                            NBadge(SText.pressure(host?.memoryPressure), tint: SText.pressureColor(host?.memoryPressure))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, NSpace.xs)
                .accessibilityElement(children: .combine)
            }
            if let load = store.cpuLoadFraction, let avg = host?.loadAvg?.first {
                CapacityBar(title: String(localized: "CPU load"),
                            value: cpuText(avg, cores: host?.cpuCount),
                            fraction: load, tint: load > 0.9 ? NColor.warning : NColor.accent, symbol: "cpu")
            }
            if let disk = store.diskUsedFraction {
                CapacityBar(title: String(localized: "Disk"),
                            value: String(localized: "\(NFormat.bytes(host?.diskFreeBytes)) free of \(NFormat.bytes(host?.diskTotalBytes))"),
                            fraction: disk, tint: disk > 0.92 ? NColor.danger : (disk > 0.8 ? NColor.warning : NColor.accent),
                            symbol: "internaldrive")
            }
            ValueRow(title: String(localized: "NEBULA server"), value: store.serverVersion ?? "–", symbol: "server.rack")
            if let os = host?.os {
                ValueRow(title: String(localized: "System"), value: [os, host?.arch].compactMap { $0 }.joined(separator: " · "),
                         symbol: "desktopcomputer")
            }
        } header: {
            HStack {
                Text("Mac mini")
                Spacer()
                if let s = store.health?.status {
                    NBadge(SText.health(s), tint: s == "ok" ? NColor.success : NColor.warning)
                }
            }
        }
    }

    private func cpuText(_ avg: Double, cores: Int?) -> String {
        let a = avg.formatted(.number.precision(.fractionLength(1)))
        guard let cores else { return a }
        return String(localized: "\(a) · \(cores) cores")
    }

    // MARK: VM

    private var vmSection: some View {
        let state = store.vmState
        let busy = store.busyAction == .vmStart || store.busyAction == .vmStop || store.vmTransition != nil
        return Section {
            HStack(spacing: NSpace.s) {
                StatusDot(color: SText.vmColor(state), pulsing: store.vmTransition != nil)
                Text(SText.vmState(state)).font(NFont.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Ubuntu VM: \(SText.vmState(state))"))
            .nAnimation(NMotion.smooth, value: state)
            if let msg = store.system?.vm?.message.flatMap({ $0.isEmpty ? nil : $0 }), !store.vmRunning {
                Text(SText.sanitize(msg, max: 300)).font(.footnote).foregroundStyle(NColor.textSecondary)
            }
            if let fp = store.system?.host?.vmFootprintBytes ?? store.system?.host?.vmResidentBytes, fp > 0 {
                ValueRow(title: String(localized: "VM memory"), value: NFormat.bytes(fp), symbol: "memorychip")
            }
            ValueRow(title: String(localized: "Service in the VM"), value: guestText, symbol: "antenna.radiowaves.left.and.right",
                     tint: store.system?.guest?.status == "ok" || store.health?.guest?.status == "ok" ? nil : NColor.warning)

            if store.vmRunning || store.vmTransition == .stopping {
                Button(role: .destructive) {
                    Task { await askStopVM() }
                } label: {
                    HStack {
                        Label("Stop VM", systemImage: "stop.circle")
                        Spacer()
                        if checkingTasks { ProgressView().controlSize(.small) }
                    }
                }
                .foregroundStyle(NColor.danger)
                .disabled(busy || checkingTasks)
            } else {
                Button {
                    Haptics.tap()
                    Task { banner = .from(await store.startVM()) }
                } label: {
                    Label("Start VM", systemImage: "play.circle")
                }
                .disabled(busy)
            }
        } header: {
            Text("Ubuntu VM")
        } footer: {
            Text("The VM runs every agent’s desktop and browser. Stopping the VM requires confirmation with Face ID or Touch ID.")
        }
    }

    private var guestText: String {
        let g = store.system?.guest
        let status = g?.status ?? store.health?.guest?.status
        var t = SText.guest(status)
        if let l = g?.latencyMs ?? store.health?.guest?.latencyMs, status == "ok" { t += " · " + SText.ms(l) }
        return t
    }

    private func askStopVM() async {
        checkingTasks = true
        let running = await store.runningTasks()
        checkingTasks = false
        Haptics.warning()
        stopCandidates = running
    }

    private func stopMessage(_ tasks: [SystemStore.RunningTask]) -> String {
        if tasks.isEmpty {
            return String(localized: "Agents cannot work or show their desktop until you start the VM again.")
        }
        let list = tasks.prefix(6).map { "• \($0.agentName) – \(SText.taskState($0.state))" }.joined(separator: "\n")
        let more = tasks.count > 6 ? "\n" + String(localized: "and more (\(tasks.count - 6))") : ""
        return String(localized: "Running tasks (\(tasks.count)) will be interrupted and paused:") + "\n" + list + more +
            "\n" + String(localized: "You can continue them once the VM is running.")
    }

    // MARK: activity

    private var activitySection: some View {
        Section {
            ValueRow(title: String(localized: "Agents"), value: store.agentCount.map(String.init) ?? "–", symbol: "person.2")
            ValueRow(title: String(localized: "Agents working now"), value: store.workingAgents.map(String.init) ?? "–",
                     symbol: "bolt.horizontal")
            if let n = store.system?.limits?.runningWorkers {
                ValueRow(title: String(localized: "Active tasks"), value: String(n), symbol: "checklist")
            }
            if let n = store.system?.limits?.activeGuiAgents {
                ValueRow(title: String(localized: "Concurrent desktops (limit)"), value: String(n), symbol: "rectangle.stack")
            }
        } header: {
            Text("Operations")
        }
    }

    // MARK: connection

    private var connectionSection: some View {
        Section {
            if let ms = store.latencyMs {
                ValueRow(title: String(localized: "Server latency"), value: SText.ms(ms), symbol: "speedometer",
                         tint: ms < 200 ? NColor.success : (ms < 600 ? NColor.warning : NColor.danger))
            }
            if let api = store.health?.api {
                ValueRow(title: String(localized: "API"), value: api == "ok" ? String(localized: "All good") : api,
                         symbol: "network")
            }
            if let db = store.health?.db {
                ValueRow(title: String(localized: "Database"), value: db == "ok" ? String(localized: "All good") : String(localized: "Error"),
                         symbol: "cylinder.split.1x2", tint: db == "ok" ? nil : NColor.danger)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Latency measures the whole round trip from this device through the NEBULA gateway to the Mac mini and back.")
        }
    }

    // MARK: maintenance

    private var maintenanceSection: some View {
        Section {
            Button {
                Haptics.tap()
                Task { banner = .from(await store.backup()) }
            } label: {
                HStack {
                    Label("Back up database", systemImage: "externaldrive.badge.checkmark")
                    Spacer()
                    if store.busyAction == .backup { ProgressView().controlSize(.small) }
                }
            }
            .disabled(store.busyAction != nil)
            if let b = store.lastBackup {
                BackupResultRow(backup: b)
            }
            Button {
                showDiagnostics = true
            } label: {
                HStack {
                    Label("Diagnostics", systemImage: "stethoscope")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        .foregroundStyle(NColor.textTertiary)
                }
                .contentShape(Rectangle())
            }
            Button(role: .destructive) {
                confirmRestart = true
            } label: {
                HStack {
                    Label("Restart services", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if store.busyAction == .restart || store.restarting { ProgressView().controlSize(.small) }
                }
            }
            .foregroundStyle(NColor.danger)
            .disabled(store.busyAction != nil || store.restarting)
        } header: {
            Text("Maintenance")
        } footer: {
            Text("The backup contains no secrets; Keychain items are never exported. Backing up and restarting require confirmation with Face ID or Touch ID.")
        }
    }
}

/// The last backup: where it is on the Mac mini and how big it is.
private struct BackupResultRow: View {
    let backup: BackupResult
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: NSpace.xs) {
            Label("Backup created", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(NColor.success)
            Text(backup.path).font(NFont.monoSmall).foregroundStyle(NColor.textSecondary).textSelection(.enabled)
                .lineLimit(3)
            HStack {
                if let s = backup.sizeBytes { Text(NFormat.bytes(s)).font(.caption).foregroundStyle(NColor.textTertiary) }
                Spacer()
                Button(copied ? "Copied" : "Copy path") {
                    copyToPasteboard(backup.path)
                    Haptics.success()
                    copied = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, NSpace.xxs)
        .nAppear()
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

func copyToPasteboard(_ s: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = s
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #endif
}

/// Memory use as a ring (tinted by the memory pressure).
struct MemoryRing: View {
    let fraction: Double
    let tint: Color
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle().stroke(NColor.surfaceSunken, lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: min(1, max(0.001, fraction)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(SText.percent(fraction)).font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("used").font(.caption2).foregroundStyle(NColor.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .nAnimation(NMotion.gentle, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(Text("Memory usage"))
        .accessibilityValue(Text(SText.percent(fraction)))
    }
}

private struct StatusSkeleton: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: NSpace.l) {
                    Skeleton(cornerRadius: 42).frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: NSpace.s) {
                        Skeleton().frame(width: 90, height: 14)
                        Skeleton().frame(width: 140, height: 12)
                        Skeleton().frame(width: 70, height: 12)
                    }
                }
                .padding(.vertical, NSpace.xs)
                Skeleton().frame(height: 10)
                Skeleton().frame(height: 10)
            }
            Section {
                ForEach(0..<3, id: \.self) { _ in Skeleton().frame(height: 14) }
            }
            Section {
                ForEach(0..<3, id: \.self) { _ in Skeleton().frame(height: 14) }
            }
        }
        .systemFormStyle()
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

// MARK: - Previews

#Preview("System") {
    NavigationStack { SystemStatusView(store: SystemPreviewData.store()) }
}
