import SwiftUI

// Presentation for the iPad app. Pure SwiftUI on plain values (no UIKit, no
// session objects), so every state can be rendered and reviewed on its own.

enum Brand {
    static let blue = Color(red: 0.12, green: 0.48, blue: 1.0)
    static let deep = Color(red: 0.04, green: 0.13, blue: 0.40)
    static let tile = LinearGradient(colors: [Color(red: 0.35, green: 0.72, blue: 1.0), blue, Color(red: 0.04, green: 0.32, blue: 0.88)],
                                     startPoint: .top, endPoint: .bottom)
}

/// Dark backdrop behind every non-streaming screen.
struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.12), .black], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Brand.blue.opacity(0.28), .clear], center: .init(x: 0.5, y: 0.3),
                           startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// A tile with a symbol, or (no symbol) the app icon itself, so the splash
/// screen shows exactly the home screen icon.
struct IconTile: View {
    var symbol: String?
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let symbol {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Brand.tile)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: size * 0.44, weight: .medium))
                            .foregroundStyle(.white)
                    )
            } else {
                Image("AppIconArt")
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Brand.blue.opacity(0.45), radius: 24, y: 10)
    }
}

// MARK: - Connection status

struct StatusInfo: Equatable {
    enum Stage: Equatable { case starting, waitingForMac, connecting, failed(String) }
    var stage: Stage
    var macName: String
    var lastError: String?
    var wirelessEnabled: Bool
    var wirelessStatus: String?
    var wirelessMacs: [WirelessMac]
}

struct StatusScreen: View {
    let info: StatusInfo
    let enableWireless: () -> Void
    let enableWired: () -> Void
    let selectWirelessMac: (String) -> Void
    /// When waiting began, for the re-plug hint (BUG-037: after the Mac
    /// restarts, the iPad stays off its USB bus until the cable is re-plugged).
    @State private var waitingSince = Date()
    static let replugHintDelay: TimeInterval = 20

    var body: some View {
        VStack(spacing: 28) {
            IconTile()
            VStack(spacing: 10) {
                Text("AutoSidecar Companion")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                statusLine
            }
            if !info.wirelessEnabled { steps }
            wirelessControls
            if info.wirelessEnabled {
                Button(action: enableWired) {
                    Label(uiText("Use a wired desktop (USB-C)"), systemImage: "cable.connector")
                }
                .buttonStyle(.bordered)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if !info.wirelessEnabled, info.stage == .waitingForMac,
                   context.date.timeIntervalSince(waitingSince) >= Self.replugHintDelay {
                    ReplugHint()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: info)
        .onChange(of: info.stage, initial: true) { _, stage in
            if stage == .waitingForMac { waitingSince = Date() }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            switch info.stage {
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .connecting, .starting:
                ProgressView().controlSize(.small).tint(.white)
            case .waitingForMac:
                PulsingDot()
            }
            Text(headline)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var headline: String {
        switch info.stage {
        case .starting: return uiText("Starting…")
        case .waitingForMac: return info.wirelessEnabled ? uiText("Waiting for your Mac") : uiText("Waiting for a wired Mac connection (USB-C)")
        case .connecting: return info.macName.isEmpty ? uiText("Connecting…") : uiText("Connecting to %@…", info.macName)
        case .failed: return uiText("Can’t start")
        }
    }

    /// The error worth showing: a failure reason, or why the last session ended.
    private var note: String? {
        if case .failed(let reason) = info.stage { return reason }
        guard info.stage == .waitingForMac, let error = info.lastError, !error.isEmpty else { return nil }
        return uiText("Last session: %@", uiText(error))
    }

    private var steps: some View {
        let connecting = info.stage == .connecting
        return VStack(alignment: .leading, spacing: 0) {
            StepRow(number: 1, symbol: "cable.connector", title: uiText("Connect the USB‑C cable"),
                    detail: uiText("For a wired connection."), done: connecting)
            Divider().overlay(.white.opacity(0.08)).padding(.leading, 64)
            StepRow(number: 2, symbol: "menubar.rectangle", title: uiText("Start AutoSidecar Companion on the Mac"),
                    detail: uiText("It lives in the menu bar and opens at login."), done: connecting)
            Divider().overlay(.white.opacity(0.08)).padding(.leading, 64)
            StepRow(number: 3, symbol: "lock.shield", title: uiText("Pair once"),
                    detail: uiText("Confirm the code the first time this iPad meets a Mac."), done: false)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder
    private var wirelessControls: some View {
        if info.stage != .connecting {
            if info.wirelessEnabled {
                VStack(spacing: 12) {
                    if let status = info.wirelessStatus {
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if !info.wirelessMacs.isEmpty {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(info.wirelessMacs) { mac in
                                    Button { selectWirelessMac(mac.id) } label: {
                                        Label(mac.name, systemImage: "wifi").frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(FilledButtonStyle(fill: Brand.blue))
                                }
                            }
                        }
                        .frame(height: min(CGFloat(info.wirelessMacs.count) * 58, 232))
                    }
                }
                .frame(maxWidth: 380)
            } else {
                Button(action: enableWireless) {
                    Label(uiText("Connect over Wi-Fi"), systemImage: "wifi").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: Brand.blue))
                .frame(maxWidth: 300)
            }
        }
    }
}

/// Shown after a while without a Mac: the usual cure after a Mac restart.
private struct ReplugHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Brand.blue.opacity(0.85), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(uiText("Mac restarted? Unplug the cable and plug it back in."))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(uiText("After a restart the Mac doesn’t see an iPad that stayed connected until the USB‑C cable is reconnected."))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(Brand.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.blue.opacity(0.4)))
    }
}

private struct StepRow: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.85) : Brand.blue.opacity(0.85))
                Image(systemName: done ? "checkmark" : symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stepDescription)
    }

    private var stepDescription: String {
        let description = uiText("Step %@: %@. %@", number.formatted(), title, detail)
        return done ? uiText("%@. Done", description) : description
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Brand.blue)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Brand.blue.opacity(0.5), lineWidth: 2).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
            .accessibilityHidden(true)
    }
}

// MARK: - Pairing

struct PairingScreen: View {
    let macName: String
    let code: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 26) {
            IconTile(symbol: "lock.shield.fill", size: 84)
            VStack(spacing: 8) {
                Text(macName.isEmpty ? uiText("Pair with this Mac?") : uiText("Pair with “%@”?", macName))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(uiText("Check that the AutoSidecar Companion menu on the Mac shows the same code."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            CodeView(code: code)
            Label(uiText("A paired Mac shows its screen here and receives this iPad’s touch, keyboard and microphone input."),
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 440)
            HStack(spacing: 14) {
                Button { answer(false) } label: {
                    Text(uiText("Don’t Pair")).frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: .white.opacity(0.12)))
                Button { answer(true) } label: {
                    Text(uiText("Pair")).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: Brand.blue))
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 440)
        }
        .padding(44)
        .frame(maxWidth: 600)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "123 456" as two groups of digit cells.
private struct CodeView: View {
    let code: String

    var body: some View {
        let groups = code.split(separator: " ").map(String.init)
        HStack(spacing: 22) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 8) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 72)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.blue.opacity(0.5)))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uiText("Pairing code %@", code))
    }
}

// MARK: - Controls panel

struct SessionSummary: Equatable {
    var macName: String
    var streaming: Bool
    var logicalSize: String?   // "1788 × 1340"
    var detail: String?        // "3180 × 2384 px · 60 Hz · HEVC"
    var framesShown: Int
    var framesDropped: Int
    var transport: String?
    var keyEventsSent: Int
    var pointerEventsSent: Int
    var speakerFramesReceived: Int
    var speakerUnderruns: Int
    var speakerFormat: String?
    var outputRoute: String? = nil
}

struct PairedMacRow: Identifiable, Equatable {
    var id: String { fingerprint }
    var name: String
    var fingerprint: String
}

/// What this iPad reports to the Mac (D-031), shown under "This iPad".
struct DeviceInfo: Equatable {
    var model: String
    var panel: String
    var pixelsPerInch: Int
    var maxRefreshHz: Int
    var hevcHardware: Bool
    var supportsHDR10: Bool = false
    var wideGamut: Bool = false
}

struct ControlsContent: View {
    let summary: SessionSummary
    @Binding var wirelessEnabled: Bool
    @Binding var speaker: Bool
    @Binding var microphone: Bool
    @Binding var smoothGradients: Bool
    var metalRenderer: Binding<Bool>? = nil
    let pairedMacs: [PairedMacRow]
    let forgetPaired: () -> Void
    let reconnect: () -> Void
    var device: DeviceInfo? = nil
    var dedicatedSpeaker = false
    @State private var confirmForget = false
    @State private var showGestures = false
    @State private var showShortcuts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                section(uiText("Connection")) {
                    ToggleRow(symbol: "wifi", title: "Wi-Fi",
                              detail: uiText("Automatically reconnects to paired Macs. Turn off to use USB-C only."),
                              isOn: $wirelessEnabled)
                    if let transport = summary.transport {
                        InfoRow(symbol: "link",
                                title: summary.streaming ? uiText("Connected over %@", transport) : uiText("Connecting over %@", transport),
                                value: nil)
                    }
                }
                section(uiText("Current Stream")) {
                    if let size = summary.logicalSize {
                        InfoRow(symbol: "rectangle.on.rectangle", title: uiText("Desktop space · %@ pt", size), value: nil)
                    }
                    if let detail = summary.detail {
                        InfoRow(symbol: "dial.medium", title: detail, value: nil, secondary: true)
                    }
                    if summary.streaming {
                        InfoRow(symbol: "film.stack", title: uiText("Frames submitted to the renderer"),
                                value: uiText("%@ submitted · %@ rejected", summary.framesShown.formatted(), summary.framesDropped.formatted()),
                                secondary: true)
                    }
                    ToggleRow(symbol: "circle.lefthalf.filled", title: uiText("Smooth gradients"),
                              detail: uiText("GPU dithering against banding."), isOn: $smoothGradients)
                    if let metalRenderer {
                        ToggleRow(symbol: "bolt.horizontal", title: uiText("Metal renderer"),
                                  detail: uiText("Draws each frame as soon as it is decoded (lower latency). Off: the system video layer."), isOn: metalRenderer)
                    }
                }
                section(uiText("Audio")) {
                    ToggleRow(symbol: "speaker.wave.2.fill", title: uiText("Mac audio on this iPad"), detail: nil, isOn: $speaker)
                    if dedicatedSpeaker {
                        if summary.streaming, speaker {
                            InfoRow(symbol: "waveform", title: uiText("Dedicated USB stereo PCM"), value: "48 kHz Float32", secondary: true)
                        }
                    } else {
                        ToggleRow(symbol: "mic.fill", title: uiText("iPad microphone to Mac"), detail: nil, isOn: $microphone)
                    }
                    if summary.streaming, speaker, !dedicatedSpeaker {
                        InfoRow(symbol: "hifispeaker", title: "iPad 實際輸出",
                                value: summary.outputRoute ?? uiText("Waiting for audio output"), secondary: true)
                        InfoRow(symbol: "waveform", title: summary.speakerFormat ?? uiText("Waiting for Mac audio"),
                                value: uiText("%@ frames received · %@ underruns", summary.speakerFramesReceived.formatted(), summary.speakerUnderruns.formatted()),
                                secondary: true)
                    }
                    if microphone {
                        Label(uiText("Live — choose “iPad Microphone” on the Mac"), systemImage: "waveform")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.leading, 38)
                    }
                }
                section(uiText("Touch")) {
                    DisclosureGroup(isExpanded: $showGestures) {
                        VStack(alignment: .leading, spacing: 10) {
                            GestureRow(symbol: "hand.tap", gesture: uiText("Tap"), action: uiText("Click"))
                            GestureRow(symbol: "hand.draw", gesture: uiText("Drag"), action: uiText("Scroll"))
                            GestureRow(symbol: "hand.point.up.left", gesture: uiText("Hold, then drag"), action: uiText("Select · move"))
                            GestureRow(symbol: "hand.tap", gesture: uiText("Two-finger tap"), action: uiText("Right click"))
                            GestureRow(symbol: "arrow.up.left.and.arrow.down.right", gesture: uiText("Pinch"), action: uiText("Zoom"))
                            GestureRow(symbol: "arrow.clockwise", gesture: uiText("Two-finger rotate"), action: uiText("Rotate"))
                            GestureRow(symbol: "hand.pinch", gesture: uiText("Three-finger pinch / spread"), action: uiText("Copy · paste"))
                            GestureRow(symbol: "arrow.uturn.backward", gesture: uiText("Three-finger swipe"), action: uiText("Undo · redo"))
                        }
                        .padding(.top, 10)
                    } label: {
                        Label(uiText("Gestures"), systemImage: "hand.raised.fingers.spread")
                            .font(.body)
                    }
                    .tint(.primary)
                    Text(uiText("Enable “Allow Input from iPad” in the Mac menu to use touch, keyboard, and trackpad input."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                section(uiText("Keyboard & trackpad")) {
                    if summary.streaming {
                        InfoRow(symbol: "keyboard", title: uiText("Input events queued"),
                                value: uiText("%@ keyboard · %@ pointer", summary.keyEventsSent.formatted(), summary.pointerEventsSent.formatted()),
                                secondary: true)
                    }
                    DisclosureGroup(isExpanded: $showShortcuts) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(uiText("iPadOS keeps these for itself, so use Control instead of Command:"))
                                .font(.footnote).foregroundStyle(.secondary)
                            ShortcutRow(keys: "⌃ Tab", mac: "⌘ Tab", action: uiText("Switch apps"))
                            ShortcutRow(keys: "⌃ ⇧ Tab", mac: "⌘ ⇧ Tab", action: uiText("Switch back"))
                            ShortcutRow(keys: "⌃ `", mac: "⌘ `", action: uiText("App windows"))
                            ShortcutRow(keys: "⌃ Space", mac: "⌘ Space", action: uiText("Spotlight"))
                            ShortcutRow(keys: "⌃ ⇧ 3 · 4 · 5", mac: "⌘ ⇧ 3 · 4 · 5", action: uiText("Screenshot"))
                            Text(uiText("Hold ⌃ and press Tab again to move through apps, like ⌘ Tab on a Mac. All other shortcuts (⌘ C, ⌘ V, ⌘ W …) go to the Mac as they are."))
                                .font(.footnote).foregroundStyle(.secondary)
                            Divider().padding(.vertical, 2)
                            GestureRow(symbol: "rectangle.and.hand.point.up.left", gesture: uiText("Two-finger scroll"), action: uiText("Scroll"))
                            GestureRow(symbol: "cursorarrow.click.2", gesture: uiText("Two-finger click"), action: uiText("Right click"))
                            GestureRow(symbol: "arrow.up.left.and.arrow.down.right", gesture: uiText("Pinch"), action: uiText("Zoom"))
                            GestureRow(symbol: "arrow.clockwise", gesture: uiText("Rotate"), action: uiText("Rotate"))
                            Text(uiText("Three- and four-finger swipes stay with iPadOS. Use ⌃ ↑ for Mission Control and ⌃ ← / → for Spaces."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                    } label: {
                        Label(uiText("Shortcuts"), systemImage: "keyboard")
                            .font(.body)
                    }
                    .tint(.primary)
                }
                if let device {
                    section(uiText("This iPad")) {
                        InfoRow(symbol: "ipad.landscape", title: uiText("Model"), value: device.model)
                        InfoRow(symbol: "square.resize", title: uiText("Panel pixels"), value: device.panel)
                        if device.pixelsPerInch > 0 {
                            InfoRow(symbol: "circle.grid.3x3", title: uiText("Pixel density"), value: "\(device.pixelsPerInch) ppi")
                        }
                        InfoRow(symbol: "gauge.with.dots.needle.67percent", title: uiText("System-reported maximum refresh rate"), value: "\(device.maxRefreshHz) Hz")
                        InfoRow(symbol: "film", title: uiText("HEVC hardware decoding"), value: device.hevcHardware ? uiText("Supported") : uiText("Uses H.264"))
                        InfoRow(symbol: "sun.max", title: uiText("HDR10 reception"), value: device.supportsHDR10 ? uiText("Available") : uiText("Uses SDR"))
                        InfoRow(symbol: "paintpalette", title: "螢幕廣色域", value: device.wideGamut ? "P3" : uiText("Standard"))
                    }
                }
                section(uiText("Security")) {
                    if pairedMacs.isEmpty {
                        InfoRow(symbol: "lock.open", title: uiText("No paired Mac"), value: nil, secondary: true)
                    } else {
                        ForEach(pairedMacs) { mac in
                            InfoRow(symbol: "lock.shield.fill", title: mac.name, value: String(mac.fingerprint.prefix(8)))
                        }
                        Button(uiText("Forget Paired Macs…"), role: .destructive) { confirmForget = true }
                            .font(.body)
                            .confirmationDialog(uiText("Forget all paired Macs?"), isPresented: $confirmForget) {
                                Button(uiText("Forget"), role: .destructive, action: forgetPaired)
                            } message: {
                                Text(uiText("The next Mac that connects must be paired again with a code."))
                            }
                    }
                }
                Button(action: reconnect) {
                    Label(uiText("Reconnect"), systemImage: "arrow.clockwise")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(fill: Brand.blue))
            }
            .padding(20)
        }
        .frame(width: 400)
        .frame(maxHeight: 700)
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.macName.isEmpty ? "AutoSidecar Companion" : summary.macName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                StatusPill(streaming: summary.streaming)
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct StatusPill: View {
    let streaming: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(streaming ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(streaming ? uiText("Streaming") : uiText("Not connected"))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background((streaming ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
        .foregroundStyle(streaming ? .green : .secondary)
    }
}

private struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String?
    var secondary = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(title)
                .font(secondary ? .subheadline : .body)
                .foregroundStyle(secondary ? .secondary : .primary)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.white)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Brand.blue)
    }
}

private struct GestureRow: View {
    let symbol: String
    let gesture: String
    let action: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 26)
            Text(gesture).font(.subheadline)
            Spacer(minLength: 8)
            Text(action).font(.subheadline.weight(.medium)).foregroundStyle(Brand.blue)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let mac: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys).font(.subheadline.monospaced().weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(mac).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(action).font(.subheadline.weight(.medium)).foregroundStyle(Brand.blue)
        }
    }
}

/// Brief indicator when the Mac changes the iPad's brightness (D-033).
struct BrightnessHUD: View {
    let value: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: value < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .foregroundStyle(.white)
            GeometryReader { proxy in
                Capsule().fill(.white.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: proxy.size.width * CGFloat(value))
                    }
            }
            .frame(width: 180, height: 6)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// The small round button that opens the controls; faint while streaming.
struct ControlsButton: View {
    let streaming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(streaming ? 0.25 : 0.45), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .opacity(streaming ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel(uiText("Session controls"))
    }
}

/// Solid, full-width capsule button with white text; the same on every
/// platform and appearance (system prominent styles can render grey).
struct FilledButtonStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// SwiftUI and AppKit share the same bundle translations. Device names and
// technical details remain arguments, so they are never read as format strings.
func uiText(_ key: String, _ arguments: CVarArg...) -> String {
    let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? localized : String(format: localized, locale: .current, arguments: arguments)
}
