import SwiftUI

struct PairingView: View {
    @State private var code = ""
    @State private var isError = false
    @State private var errorMessage = ""
    @State private var relayUrlDraft = ""
    @ObservedObject private var relay = RelayClient.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Text("Nexus")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)

                Text("Enter the 6-digit pairing code")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(height: 52)

                    TextField("", text: $code)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .padding(.horizontal, 16)
                        .onChange(of: code) { newValue in
                            if newValue.count > 6 {
                                code = String(newValue.prefix(6))
                            }
                        }
                }
                .frame(width: 200)

                if isError {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }

                Button(action: startPairing) {
                    Text("Pair")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 140, height: 42)
                        .background(code.count == 6 ? Color.blue : Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
                .disabled(code.count != 6 || isConnecting)
            }
            .padding(.horizontal, 32)

            if isConnecting {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Color.blue)
                    Text(statusText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 24)
            }

            // Relay server config — must be reachable BEFORE pairing, so it
            // lives on the pairing screen, not hidden in Dashboard settings.
            relayConfigCard

            Spacer()
        }
        .onAppear {
            relayUrlDraft = UserDefaults.standard.string(forKey: "relay_url") ?? relay.currentRelayURL
        }
    }

    private var relayConfigCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                Text("Relay Server")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("Current: \(relay.currentRelayURL)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            TextField("wss://your-relay-domain/relay", text: $relayUrlDraft)
                .font(.system(size: 14, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))

            Button(action: saveRelayUrl) {
                Text("Save & Reconnect")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    private func saveRelayUrl() {
        let trimmed = relayUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme == "wss" || url.scheme == "ws" else {
            isError = true
            errorMessage = "Enter a valid wss:// relay URL"
            return
        }
        UserDefaults.standard.set(trimmed, forKey: "relay_url")
        relay.disconnect()
        relay.connect()
    }

    private var isConnecting: Bool {
        switch relay.pairingState {
        case .connecting, .waitingForAgent, .exchangingKeys:
            return true
        default:
            return false
        }
    }

    private var statusText: String {
        switch relay.pairingState {
        case .connecting:
            return "Connecting to relay..."
        case .waitingForAgent:
            return "Waiting for agent..."
        case .exchangingKeys:
            return "Exchanging keys..."
        case .paired:
            return "Paired!"
        case .error(let msg):
            isError = true
            errorMessage = msg
            return msg
        case .idle:
            return ""
        }
    }

    private func startPairing() {
        isError = false
        relay.pair(withCode: code)
    }
}