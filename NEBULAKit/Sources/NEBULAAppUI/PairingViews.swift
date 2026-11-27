import NEBULAAuth
import NEBULACore
import NEBULADesignSystem
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// First launch: connect this iPhone / Mac to the owner's NEBULA (QR code from the Mac dashboard, or a pasted link).
public struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var link = ""
    @State private var scanning = false
    @State private var name = WelcomeView.defaultName()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(spacing: NSpace.xl) {
                Spacer(minLength: NSpace.xxl)
                ZStack {
                    Circle().fill(NColor.accentGradient).frame(width: 112, height: 112)
                        .blur(radius: glow ? 28 : 18).opacity(0.55)
                    Image(systemName: "sparkles").font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(NColor.accentGradient))
                }
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
                }
                .accessibilityHidden(true)
                VStack(spacing: NSpace.s) {
                    Text("NEBULA").font(NFont.largeTitle)
                    Text("Your agents from your Mac mini, securely in your pocket and on your MacBook.")
                        .font(.title3).multilineTextAlignment(.center).foregroundStyle(NColor.textSecondary)
                }
                NCard {
                    VStack(alignment: .leading, spacing: NSpace.m) {
                        Label("Connect to NEBULA", systemImage: "link").font(.headline)
                        // the Dashboard's top-level "Devices" page and its button (apps/dashboard: nav.devices, devices.pair)
                        Text("On your Mac, open the NEBULA Dashboard → Devices → “Pair an iPhone or Mac”.")
                            .font(.callout).foregroundStyle(NColor.textSecondary)
                        #if os(iOS)
                        Button {
                            Haptics.tap()
                            scanning = true
                        } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(NPrimaryButtonStyle())
                            .disabled(model.pairingBusy)
                        #endif
                        TextField("…or paste a nebula://pair link…", text: $link, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Device name", text: $name).textFieldStyle(.roundedBorder)
                        Button {
                            Task { await model.pair(link: link, deviceName: name) }
                        } label: {
                            HStack { if model.pairingBusy { ProgressView() }; Text("Pair") }
                        }
                        .buttonStyle(NSecondaryButtonStyle())
                        .disabled(link.isEmpty || model.pairingBusy)
                        if let e = model.pairingError { NBanner(e, style: .danger) }
                    }
                }
                .frame(maxWidth: 520)
                VStack(alignment: .leading, spacing: NSpace.s) {
                    if DeviceKeys.secureEnclaveInUse {
                        Label("Device keys stay in the Secure Enclave", systemImage: "lock.shield")
                    } else {
                        Label("Device keys stay on this device", systemImage: "lock.shield")
                    }
                    Label("The connection goes only through your Mac’s encrypted gateway", systemImage: "network.badge.shield.half.filled")
                    Label("You unlock the vault with a single \(OwnerPresence.label)", systemImage: OwnerPresence.symbol)
                }
                .font(.footnote).foregroundStyle(NColor.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(NSpace.xl)
            .frame(maxWidth: .infinity)
        }
        .background(NColor.background)
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            QRScanSheet { code in
                scanning = false
                link = code
                Task { await model.pair(link: code, deviceName: name) }
            } onCancel: { scanning = false }
        }
        #endif
        .onOpenURL { url in
            if url.scheme == "nebula" { link = url.absoluteString }
        }
    }

    static func defaultName() -> String {
        #if os(iOS)
        return UIDevice.current.name.isEmpty ? "iPhone" : UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// Waiting for the owner to approve this device on the Mac (the same 6 digits on both screens).
public struct PendingApprovalView: View {
    let code: String?
    let onCancel: () -> Void
    public init(code: String?, onCancel: @escaping () -> Void) { self.code = code; self.onCancel = onCancel }

    public var body: some View {
        VStack(spacing: NSpace.xl) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Confirm the device on your Mac").font(NFont.title)
            Text("In the NEBULA Dashboard, check that the code matches and click Approve.")
                .font(.callout).foregroundStyle(NColor.textSecondary).multilineTextAlignment(.center)
            if let code {
                Text(code.map(String.init).joined(separator: " "))
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.horizontal, NSpace.xl).padding(.vertical, NSpace.m)
                    .background(RoundedRectangle(cornerRadius: NRadius.l, style: .continuous).fill(NColor.surface))
                    .accessibilityLabel(Text("Verification code \(code)"))
            }
            Spacer()
            Button("Unpair", role: .destructive, action: onCancel)
        }
        .padding(NSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NColor.background)
    }
}

public struct BlockedView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    public init(title: LocalizedStringKey, message: LocalizedStringKey, symbol: String, action: @escaping () -> Void) {
        self.title = title; self.message = message; self.symbol = symbol; self.action = action
    }
    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Pair again", action: action).buttonStyle(.borderedProminent).tint(NColor.accent)
        }
    }
}

#if os(iOS)
/// VisionKit live QR scanner (falls back to a message when the camera is unavailable).
struct QRScanSheet: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner(onCode: onCode).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera not available", systemImage: "camera.fill",
                                           description: Text("Allow NEBULA to use the camera in Settings, or paste the link."))
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
            .navigationTitle("Scan the code from your Mac")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, recognizesMultipleItems: false,
                                           isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let b) = item, let s = b.payloadStringValue, s.hasPrefix("nebula://pair") {
                    done = true
                    scanner.stopScanning()
                    Task { @MainActor in
                        Haptics.success()
                        self.onCode(s)
                    }
                    return
                }
            }
        }
    }
}
#endif
