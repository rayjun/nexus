import SwiftUI

struct PairingView: View {
    @State private var relayUrl = ""
    @State private var code = ""
    @State private var serverName = ""
    @State private var isError = false
    @State private var errorMessage = ""
    @State private var isAdding = false
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

                if isError {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

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
    }

    private var canAdd: Bool {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return !relayUrl.isEmpty && trimmedCode.count >= 8
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
