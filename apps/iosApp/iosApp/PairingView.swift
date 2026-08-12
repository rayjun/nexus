import SwiftUI

struct PairingView: View {
    @State private var relayUrl = ""
    @State private var code = ""
    @State private var serverName = ""
    @State private var isError = false
    @State private var errorMessage = ""
    @State private var isAdding = false
    @State private var isShowingScanner = false
    @ObservedObject private var relay = RelayClient.shared
    @State private var pairingObserver: NSObjectProtocol?

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
        }
        .sheet(isPresented: $isShowingScanner) {
            QRScannerView(
                onScan: { payload in
                    isShowingScanner = false
                    applyScannedPayload(payload)
                },
                onCancel: { isShowingScanner = false }
            )
            .ignoresSafeArea()
        }
    }

    /// Parse a scanned nexus://<relay>?code=<CODE>[&name=<NAME>] payload and
    /// pre-fill the form. Mirrors the agent's _parse_qr_payload.
    private func applyScannedPayload(_ payload: String) {
        guard let url = URL(string: payload), url.scheme == "nexus",
              let host = url.host else {
            isError = true
            errorMessage = "Not a valid Nexus pairing QR"
            return
        }
        // url.host excludes the scheme AND the port; url.path keeps the path
        var hostPort = host
        if let port = url.port {
            hostPort += ":\(port)"
        }
        let relay = "wss://\(hostPort)\(url.path)"
        if let comps = URLComponents(string: payload),
           let codeValue = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            let trimmed = codeValue.uppercased()
            guard trimmed.count >= 8,
                  trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
                isError = true
                errorMessage = "Pairing code in QR is invalid"
                return
            }
            code = trimmed
            if let nameValue = comps.queryItems?.first(where: { $0.name == "name" })?.value,
               !nameValue.isEmpty {
                serverName = nameValue
            }
            relayUrl = relay
            isError = false
            errorMessage = ""
        } else {
            isError = true
            errorMessage = "Pairing QR is missing the code"
        }
    }

    private var canAdd: Bool {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return !relayUrl.isEmpty && trimmedCode.count >= 8
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
        var relayPart = trimmedRelay
        for scheme in ["wss://", "ws://"] {
            if relayPart.hasPrefix(scheme) {
                relayPart = String(relayPart.dropFirst(scheme.count))
                break
            }
        }
        var payload = "nexus://\(relayPart)?code=\(trimmedCode)"
        if !name.isEmpty {
            payload += "&name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
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
        guard trimmedCode.count >= 8, trimmedCode.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
            isError = true
            errorMessage = "Enter the 8-character pairing code from the agent"
            return
        }
        isAdding = true
        UserDefaults.standard.set(trimmedRelay, forKey: "relay_url")
        let displayName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        relay.addServer(relayURL: trimmedRelay, name: displayName.isEmpty ? nil : displayName, code: trimmedCode)
        // Listen for pairing completion or failure; stop the spinner either way.
        pairingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RelayPaired"),
            object: nil, queue: .main
        ) { _ in
            self.isAdding = false
            self.removeObserver()
        }
        pairingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RelayPairingFailed"),
            object: nil, queue: .main
        ) { note in
            self.isAdding = false
            let msg = (note.userInfo?["message"] as? String) ?? "Pairing failed"
            self.isError = true
            self.errorMessage = msg
            self.removeObserver()
        }
    }

    private func removeObserver() {
        if let pairingObserver {
            NotificationCenter.default.removeObserver(pairingObserver)
        }
        pairingObserver = nil
    }
}
