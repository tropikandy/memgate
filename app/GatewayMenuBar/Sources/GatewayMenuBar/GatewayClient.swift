import Foundation

struct ModelStatus: Decodable, Identifiable {
    let id: String
    let status: StatusValue

    struct StatusValue: Decodable {
        let value: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, status
    }
}

struct ModelsResponse: Decodable {
    let data: [ModelStatus]
}

struct WardenLock: Decodable {
    let reason: String?
    let requested_by: String?
}

struct WardenState: Decodable {
    let level: Int
    let lock_held: Bool
    let lock: WardenLock?
}

enum ResidentModel: Equatable {
    case none
    case loaded(id: String)

    var shortLabel: String {
        switch self {
        case .none: return "Idle"
        case .loaded(let id):
            if id.contains("27b") { return "27B" }
            if id.contains("4b") { return "4B" }
            return id
        }
    }
}

@MainActor
final class GatewayClient: ObservableObject {
    @Published var resident: ResidentModel = .none
    @Published var wardenLevel: Int = 0
    @Published var lockHeld: Bool = false
    @Published var lockReason: String?
    @Published var reachable: Bool = false

    private let gatewayBase = URL(string: "http://127.0.0.1:8000")!
    private let wardenBase = URL(string: "http://127.0.0.1:8011")!
    private var timer: Timer?

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        async let models = fetchModels()
        async let warden = fetchWardenState()
        let (m, w) = await (models, warden)

        if let m {
            reachable = true
            if let loaded = m.data.first(where: { $0.status.value == "loaded" }) {
                resident = .loaded(id: loaded.id)
            } else {
                resident = .none
            }
        } else {
            reachable = false
        }

        if let w {
            wardenLevel = w.level
            lockHeld = w.lock_held
            lockReason = w.lock?.reason
        }
    }

    private func fetchModels() async -> ModelsResponse? {
        guard let url = URL(string: "/v1/models", relativeTo: gatewayBase) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(ModelsResponse.self, from: data)
    }

    private func fetchWardenState() async -> WardenState? {
        guard let url = URL(string: "/state", relativeTo: wardenBase) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(WardenState.self, from: data)
    }

    func pauseModelLoading() async {
        guard let url = URL(string: "/yield", relativeTo: wardenBase) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "reason": "paused from menu bar",
            "requested_by": "GatewayMenuBar",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    func resumeModelLoading() async {
        guard let url = URL(string: "/release", relativeTo: wardenBase) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        await refresh()
    }

    /// Restarts the gateway infrastructure via launchctl kickstart -- the
    /// same LaunchAgents WP-008/WP-014 install (com.local.llama-swap,
    /// com.local.memwarden). Requires those labels to exist; this app
    /// does not install them itself (see docs/gateway-app.md).
    func restartInfrastructure() async {
        let uid = getuid()
        for label in ["com.local.llama-swap", "com.local.memwarden"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
            try? process.run()
            process.waitUntilExit()
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await refresh()
    }
}
