import SwiftUI

struct PairingView: View {
    @State private var code = ""
    @State private var isError = false
    @State private var errorMessage = ""
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

            Spacer()
        }
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