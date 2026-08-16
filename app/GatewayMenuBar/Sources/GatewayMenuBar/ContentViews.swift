import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var client: GatewayClient

    // Status items render as monochrome template images by default, auto-
    // adapting to light/dark menu bars -- applying .foregroundStyle/
    // .symbolRenderingMode(.hierarchical) breaks that (found live: the
    // icon silently stopped rendering at all, isolated via a minimal
    // MenuBarExtra test). Differentiate state by symbol *shape* instead
    // of color, which is also the more standard menu bar convention.
    private var symbolName: String {
        if !client.reachable { return "questionmark.circle" }
        if client.wardenLevel >= 4 { return "exclamationmark.triangle.fill" }
        if client.wardenLevel >= 3 { return "pause.circle.fill" }
        switch client.resident {
        case .none: return "circle.dotted"
        case .loaded(let id): return id.contains("27b") ? "square.fill" : "circle.fill"
        }
    }

    var body: some View {
        Image(systemName: symbolName)
    }
}

struct MenuContentView: View {
    @ObservedObject var client: GatewayClient
    @State private var showRestartConfirm = false
    @State private var restarting = false

    private var statusLine: String {
        if !client.reachable { return "Gateway unreachable" }
        if client.lockHeld { return "Paused — \(client.lockReason ?? "yielded")" }
        switch client.resident {
        case .none: return "Idle"
        case .loaded(let id): return "Serving \(id)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MenuBarLabelView(client: client)
                    Text(statusLine)
                        .font(.system(size: 13, weight: .medium))
                }
                Text("ladder level \(client.wardenLevel) · :8000 / :8011")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Button {
                Task {
                    if client.lockHeld {
                        await client.resumeModelLoading()
                    } else {
                        await client.pauseModelLoading()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: client.lockHeld ? "play.circle" : "pause.circle")
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(client.lockHeld ? "Resume model loading" : "Pause model loading")
                            .font(.system(size: 13))
                        Text(client.lockHeld
                             ? "Removes the yield lock, restores normal service"
                             : "Drains and unloads now, blocks new loads")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                showRestartConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle")
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Restart Gateway Infrastructure")
                            .font(.system(size: 13))
                        Text("Restarts llama-swap and memwarden")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if restarting {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(restarting)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit").font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 280)
        .confirmationDialog(
            "Restart gateway infrastructure?",
            isPresented: $showRestartConfirm,
            titleVisibility: .visible
        ) {
            Button("Restart", role: .destructive) {
                restarting = true
                Task {
                    await client.restartInfrastructure()
                    restarting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any resident model unloads and the gateway restarts. In-flight requests are interrupted.")
        }
    }
}
