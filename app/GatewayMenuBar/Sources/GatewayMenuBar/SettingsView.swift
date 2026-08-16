import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: GatewayClient

    @AppStorage(GatewayAppSettings.gatewayURLKey) private var gatewayURL: String = GatewayAppSettings.defaultGatewayURL
    @AppStorage(GatewayAppSettings.wardenURLKey) private var wardenURL: String = GatewayAppSettings.defaultWardenURL
    @AppStorage(GatewayAppSettings.pollIntervalKey) private var pollInterval: Double = GatewayAppSettings.defaultPollInterval

    @State private var saved = false

    var body: some View {
        Form {
            Section("Endpoints") {
                LabeledContent("Gateway URL") {
                    TextField("http://127.0.0.1:8000", text: $gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledContent("memwarden URL") {
                    TextField("http://127.0.0.1:8011", text: $wardenURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            Section("Polling") {
                LabeledContent("Refresh every") {
                    HStack {
                        Slider(value: $pollInterval, in: 2...30, step: 1)
                            .frame(width: 150)
                        Text("\(Int(pollInterval))s")
                            .frame(width: 32, alignment: .trailing)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                HStack {
                    Button("Reset to Defaults") {
                        gatewayURL = GatewayAppSettings.defaultGatewayURL
                        wardenURL = GatewayAppSettings.defaultWardenURL
                        pollInterval = GatewayAppSettings.defaultPollInterval
                        apply()
                    }
                    Spacer()
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                    if saved {
                        Text("Applied")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 260)
        .navigationTitle("Gateway Settings")
    }

    private func apply() {
        client.restartTimer()
        Task { await client.refresh() }
        withAnimation { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { saved = false }
        }
    }
}
