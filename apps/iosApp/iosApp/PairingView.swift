import SwiftUI

struct PairingView: View {
    /// Optional external payload (nexus:// deep link) — pre-fills the form
    /// and shows the confirmation alert exactly like a scanned QR.
    /// When `autoPair` is true (external deep link: user intent is explicit),
    /// parsing a valid payload starts pairing immediately.
    var pendingPayload: String? = nil
    var autoPair: Bool = false

    @State private var relayUrl = ""
    @State private var code = ""
    @State private var serverName = ""
    @State private var isError = false
    @State private var errorMessage = ""
    @State private var isAdding = false
    @State private var isShowingScanner = false
    @ObservedObject private var relay = RelayClient.shared
    @State private var pairedObserver: NSObjectProtocol?
    @State private var failureObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Text("Nexus")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)

                Text("Add your Hermes server")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)

                // Relay URL
                VStack(alignment: .leading, spacing: 6) {
                    Text("Relay URL")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("wss://relay.example.com/relay", text: $relayUrl)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                }

                // Server name (optional)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server name (optional)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("My Agent", text: $serverName)
                        .font(.system(size: 15))
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                }

                // Pairing code
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code (from the agent)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("K7M2P9QX", text: $code)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.blue.opacity(0.6), lineWidth: 1.5))
                }

                // Pairing QR — the agent shows 'nexus-agent pair'; scanning
                // the code pre-fills relay + code + name on this phone.
                if let qr = pairingQR {
                    VStack(spacing: 8) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 168, height: 168)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text("Scan on the agent side (nexus-agent pair --qr) or type the code")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if isError {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                // Scan the agent's terminal QR (nexus-agent pair) to
                // pre-fill relay URL + code automatically.
                Button(action: { isShowingScanner = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Scan agent QR")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: startPairing) {
                    Text(isAdding ? "Adding…" : "Add Server")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(canAdd ? Color.blue : Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
                .disabled(!canAdd || isAdding)
            }
            .padding(.horizontal, 28)

            if isAdding {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.blue)
                    Text("Pairing with agent…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
            }

            Spacer()
        }
        .onAppear {
            if relayUrl.isEmpty {
                relayUrl = UserDefaults.standard.string(forKey: "relay_url")
                    ?? (Bundle.main.object(forInfoDictionaryKey: "NexusRelayURL") as? String)
                    ?? "wss://relay.example.com/relay"
            }
            // External deep-link payload (nexus://…) — same path as a QR scan.
            if let payload = pendingPayload {
                if autoPair {
                    // Deep link: intent explicit — parse and pair directly.
                    let parsed = parseScannedPayload(payload)
                    if let parsed {
                        fillForm(from: parsed)
                        startPairing()
                    }
                } else {
                    handleScannedPayload(payload)
                }
            }
        }
        .onDisappear {
            // The view can be torn down mid-pairing (root swap) — never
            // leak observers that capture self.
            removeObservers()
        }
        .sheet(isPresented: $isShowingScanner) {
            QRScannerView(
                onScan: { payload in
                    isShowingScanner = false
                    handleScannedPayload(payload)
                },
                onCancel: { isShowingScanner = false }
            )
            .ignoresSafeArea()
        }
        .alert("Confirm relay", isPresented: $isShowingConfirmAlert) {
            Button("Cancel", role: .cancel) { pendingScan = nil }
            Button("Pair") {
                if let parsed = pendingScan { fillForm(from: parsed) }
                pendingScan = nil
            }
        } message: {
            Text("Pair with relay:\n\(pendingScan?.relay ?? "")\n\nCode: \(pendingScan?.code ?? "")\nServer: \(pendingScan?.name ?? "(unnamed)")")
        }
    }

    @State private var isShowingConfirmAlert = false
    private struct ScannedPairing: Equatable {
        let relay: String
        let code: String
        let name: String
    }
    @State private var pendingScan: ScannedPairing?

    /// Parse a nexus:// pairing payload → ScannedPairing (no side effects).
    /// Errors are reported by setting isError/errorMessage for UI display.
    private func parseScannedPayload(_ payload: String) -> ScannedPairing? {
        var normalized = payload
        if normalized.lowercased().hasPrefix("nexus://") {
            let body = String(normalized.dropFirst("nexus://".count))
            let bodyLower = body.lowercased()
            for inner in ["wss://", "ws://"] {
                if bodyLower.hasPrefix(inner) {
                    normalized = "nexus://" + String(body.dropFirst(inner.count))
                    break
                }
            }
        }
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "nexus",
              let host = url.host else {
            isError = true
            errorMessage = "Not a valid Nexus pairing QR"
            return nil
        }
        var hostPort = host
        if let port = url.port {
            hostPort += ":\(port)"
        }
        // DEBUG: a loopback/locahost pair uses ws:// (no TLS locally) —
        // mirrors startPairing's schemeOK rule; production keeps wss://.
        var scheme = "wss"
        if isDebugBuild, host == "127.0.0.1" || host == "localhost" || host == "::1" {
            scheme = "ws"
        }
        let relay = "\(scheme)://\(hostPort)\(url.path)"
        guard let comps = URLComponents(string: normalized),
              let codeValue = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            isError = true
            errorMessage = "Pairing QR is missing the code"
            return nil
        }
        let trimmed = codeValue.uppercased()
        guard trimmed.count >= 8, trimmed.count <= 12,
              trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
            isError = true
            errorMessage = "Pairing code in QR is invalid"
            return nil
        }
        let name = String((comps.queryItems?.first(where: { $0.name == "name" })?.value ?? "").prefix(64))
        return ScannedPairing(relay: relay, code: trimmed, name: name)
    }

    /// Scan step 1: parse the payload; if valid, ask the user to CONFIRM the
    /// relay before filling the form (a hostile QR must not silently point
    /// the app at an attacker-controlled relay).
    private func handleScannedPayload(_ payload: String) {
        guard let parsed = parseScannedPayload(payload) else { return }
        // Show the confirmation alert before anything is applied.
        pendingScan = parsed
        isShowingConfirmAlert = true
    }

    /// Scan step 2: user confirmed — fill the form (still editable before
    /// Add Server is actually tapped).
    private func fillForm(from scanned: ScannedPairing) {
        relayUrl = scanned.relay
        code = scanned.code
        if !scanned.name.isEmpty {
            serverName = scanned.name
        }
        isError = false
        errorMessage = ""
    }

    private var canAdd: Bool {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Align with startPairing's real rule: 8-12 alphanumeric.
        return !relayUrl.isEmpty && trimmedCode.count >= 8 && trimmedCode.count <= 12
            && trimmedCode.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
    }

    /// QR payload: nexus://<relay>?code=<CODE>&name=<name>
    /// The agent's 'nexus-agent pair --qr <payload>' consumes this.
    private var pairingQR: UIImage? {
        let trimmedRelay = relayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRelay.isEmpty, trimmedCode.count >= 8 else { return nil }
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize so the QR is nexus://<host/path> — strip any scheme the
        // relay field already carries (the agent re-adds wss://).
        // Case-insensitive: 'WSS://host' must strip just like 'wss://host'.
        var relayPart = trimmedRelay
        let lowered = relayPart.lowercased()
        for scheme in ["wss://", "ws://"] {
            if lowered.hasPrefix(scheme) {
                relayPart = String(relayPart.dropFirst(scheme.count))
                break
            }
        }
        // Reject relays that can't round-trip through a QR cleanly
        guard !relayPart.contains("?"), !relayPart.contains("#"),
              !relayPart.contains(where: { $0.isWhitespace }) else { return nil }
        // Strict encoding: code/name must not smuggle '&' or '=' into the
        // query string (which would inject extra params on decode).
        let queryAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let safeCode = trimmedCode.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? trimmedCode
        var payload = "nexus://\(relayPart)?code=\(safeCode)"
        if !name.isEmpty {
            let safeName = name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? name
            payload += "&name=\(safeName)"
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Upscale to a crisp 336pt image
        let transform = CGAffineTransform(scaleX: 14, y: 14)
        let scaled = output.transformed(by: transform)
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func startPairing() {
        // Re-entry guard: a fast double-tap can run this twice before the
        // button's disabled state applies — that would add two servers for
        // the same channel.
        guard !isAdding else { return }
        isError = false
        let trimmedRelay = relayUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let url = URL(string: trimmedRelay) else {
            isError = true
            errorMessage = "Enter a valid relay URL"
            return
        }
        // Production requires TLS. DEBUG builds additionally allow ws:// to a
        // loopback/local relay for simulator testing.
        let schemeOK = url.scheme == "wss" || (isDebugBuild && url.scheme == "ws" && isLocalHost(url))
        guard schemeOK else {
            isError = true
            errorMessage = "Relay must use wss:// (TLS)"
            return
        }
        guard trimmedCode.count >= 8, trimmedCode.count <= 12,
              trimmedCode.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
            isError = true
            errorMessage = "Enter the 8-character pairing code from the agent"
            return
        }
        isAdding = true
        UserDefaults.standard.set(trimmedRelay, forKey: "relay_url")
        let displayName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        relay.addServer(relayURL: trimmedRelay, name: displayName.isEmpty ? nil : displayName, code: trimmedCode)
        // Listen for pairing completion or failure; stop the spinner either way.
        // TWO separate tokens: one slot would overwrite the first observer,
        // leaking it (and its self-capturing closure) forever.
        pairedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RelayPaired"),
            object: nil, queue: .main
        ) { _ in
            // self is a struct — value capture, no retain cycle. The
            // previously-leaked observers were a token-overwrite bug, not
            // a capture-cycle bug.
            self.isAdding = false
            self.removeObservers()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RelayPairingFailed"),
            object: nil, queue: .main
        ) { note in
            self.isAdding = false
            let msg = (note.userInfo?["message"] as? String) ?? "Pairing failed"
            self.isError = true
            self.errorMessage = msg
            self.removeObservers()
        }
    }

    private func removeObservers() {
        if let pairedObserver {
            NotificationCenter.default.removeObserver(pairedObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        pairedObserver = nil
        failureObserver = nil
    }

    private func removeObserver() {
        // Legacy alias — kept for call-site compatibility.
        removeObservers()
    }
}
