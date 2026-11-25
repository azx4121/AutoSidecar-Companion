import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import Darwin
import WDMacAudio

enum PortableSetup {
    static let bundleID = "org.autosidecar.companion.host"

    static func receiverDownloadURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let pattern: String
        switch parts.host?.lowercased() {
        case "apps.apple.com": pattern = #"^/(?:[a-zA-Z]{2}/)?app/(?:[^/]+/)?id[1-9][0-9]*/?$"#
        case "testflight.apple.com": pattern = #"^/join/[a-zA-Z0-9]{8}/?$"#
        default: return nil
        }
        guard parts.percentEncodedPath.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return parts.url
    }

    static var receiverURL: URL? {
        receiverDownloadURL(Bundle.main.object(forInfoDictionaryKey: "AutoSidecarReceiverURL") as? String)
    }

    @MainActor
    static func receiverCode(_ url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let background = CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -4, dy: -4))
        let scale = max(1, min(5, floor(220 / background.extent.width)))
        let image = code.composited(over: background).transformed(by: .init(scaleX: scale, y: scale))
        guard let bitmap = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: image.extent.size)
    }

    @MainActor
    private static func codeView(_ image: NSImage) -> NSImageView {
        let view = NSImageView(image: image)
        view.setAccessibilityLabel(uiText("iPad receiver download code"))
        return view
    }

    @MainActor
    static func showReceiverDownload() {
        guard let url = receiverURL, let image = receiverCode(url) else { return }
        let alert = NSAlert()
        alert.messageText = uiText("Download the iPad receiver")
        alert.informativeText = uiText("Scan the code with the iPad camera. Install and open the receiver, then connect the iPad to this Mac with a USB-C data cable.")
        alert.accessoryView = codeView(image)
        alert.addButton(withTitle: uiText("Done"))
        alert.runModal()
    }

    // Match the installed executable for this account. A staging copy or a
    // controller with the same name in a different directory is independent.
    static func legacyControllerIsRunning() -> Bool {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoSidecar/auto-sidecar")
            .resolvingSymlinksInPath().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "-u", String(getuid()), "auto-sidecar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return false }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).contains { field in
            guard let pid = pid_t(field) else { return false }
            var buffer = [CChar](repeating: 0, count: 4096)
            let size = UInt32(buffer.count)
            guard proc_pidpath(pid, &buffer, size) > 0 else { return false }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected
        }
    }

    @MainActor
    static func printCheck() {
        let checks: [String: Bool] = [
            "hasBuiltInScreen": NSScreen.screens.contains {
                guard let id = $0.deviceDescription[.init("NSScreenNumber")] as? UInt32 else { return false }
                return CGDisplayIsBuiltin(id) != 0
            },
            "legacyControllerRunning": legacyControllerIsRunning(),
            "speakerDriverReady": (try? AudioDevices.speakerLoopback(preferBlackHole: false)) != nil,
            "postEventsGranted": CGPreflightPostEventAccess(),
            "screenCaptureGranted": CGPreflightScreenCaptureAccess(),
            "audioCaptureGranted": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        ]
        if let data = try? JSONEncoder().encode(checks) { print(String(decoding: data, as: UTF8.self)) }
    }

    @MainActor
    static func prepare() -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if legacyControllerIsRunning() {
            let alert = NSAlert()
            alert.messageText = uiText("This Mac is already managed by AutoSidecar")
            alert.informativeText = uiText("The existing AutoSidecar controller is managing the iPad. To set up a different Mac, open AutoSidecar Companion on that Mac.")
            alert.addButton(withTitle: uiText("Quit Companion"))
            app.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
        let key = "didPresentPortableSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return true }
        let alert = NSAlert()
        alert.messageText = uiText("Connect your iPad to this Mac")
        let code = receiverURL.flatMap(receiverCode)
        let installation = code == nil
            ? uiText("Open the AutoSidecar receiver on your iPad. If you need to install it, contact the provider of this build.")
            : uiText("Scan the code below with the iPad camera, then install and open the receiver. If already installed, open the receiver.")
        let pairing = uiText("Connect and unlock your iPad with a USB-C data cable. If prompted, trust this Mac. Compare the pairing codes and confirm on both devices.")
        let permissions = uiText("Allow Screen Recording to share the Mac desktop and Microphone access to read the virtual audio device. Reopen the app if macOS asks.")
        alert.informativeText = [installation, pairing, permissions].joined(separator: "\n\n")
        let input = NSButton(checkboxWithTitle: uiText("Let the iPad control this Mac (requires system permission)"), target: nil, action: nil)
        input.state = .off
        input.sizeToFit()
        if let code {
            let stack = NSStackView(views: [codeView(code), input])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.setFrameSize(stack.fittingSize)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = input
        }
        alert.addButton(withTitle: uiText("Start Setup"))
        alert.addButton(withTitle: uiText("Later"))
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(input.state == .on, forKey: HostController.allowInputKey)
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
}

// SwiftUI and AppKit share the same bundle translations. Device names and
// technical details remain arguments, so they are never read as format strings.
func uiText(_ key: String, _ arguments: CVarArg...) -> String {
    let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? localized : String(format: localized, locale: .current, arguments: arguments)
}
