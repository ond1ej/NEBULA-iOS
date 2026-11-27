import Foundation
import NEBULACore
import NEBULANetwork

/// Sample data for SwiftUI previews (decoded from JSON literals in the server's wire format).
@MainActor
enum SystemPreviewData {
    static let now = Date().timeIntervalSince1970

    static var health: Health? {
        SRemodel.decode(json: """
        {"status": "ok", "api": "ok", "db": "ok", "vm": {"state": "running"},
         "guest": {"status": "ok", "latency_ms": 1.8}, "version": "1.0.0"}
        """)
    }

    static var system: SystemInfo? {
        SRemodel.decode(json: """
        {"host": {"memory_total_bytes": 17179869184, "memory_available_bytes": 5368709120, "memory_free_percent": 31,
                  "memory_pressure": "normal", "load_avg": [2.4, 2.1, 1.9], "cpu_count": 10,
                  "disk_total_bytes": 494384795648, "disk_free_bytes": 171798691840,
                  "vm_footprint_bytes": 3221225472, "os": "macOS 26.1", "arch": "arm64", "app_version": "1.0.0"},
         "vm": {"state": "running"}, "guest": {"status": "ok", "latency_ms": 1.8},
         "limits": {"active_gui_agents": 3, "running_workers": 1}}
        """)
    }

    static var devices: [AppDevice] {
        SRemodel.decode(json: """
        [{"id": "d1", "name": "iPhone", "platform": "ios", "model": "iPhone 17 Pro", "app_version": "1.0.0",
          "key_protection": "secure_enclave", "status": "active", "created_at": \(now - 86400 * 9),
          "last_seen_at": \(now - 20), "vault_key": true},
         {"id": "d2", "name": "MacBook Air", "platform": "macos", "model": "MacBook Air (M4)", "app_version": "1.0.0",
          "key_protection": "secure_enclave", "status": "active", "created_at": \(now - 86400 * 5),
          "last_seen_at": \(now - 7200), "vault_key": false},
         {"id": "d3", "name": "iPad", "platform": "ios", "model": "iPad Air", "app_version": "1.0.0",
          "key_protection": "keychain", "status": "pending", "created_at": \(now - 60), "verification_code": "482 913"}]
        """) ?? []
    }

    static func store() -> SystemStore {
        let api = APIClient(baseURL: URL(string: "https://nebula.invalid") ?? URL(fileURLWithPath: "/"), tokens: nil)
        let s = SystemStore(api: api, hub: EventHub(), gate: OwnerGate())
        s.seedPreview(health: health, system: system, latencyMs: 84, agents: 4, working: 1, devices: devices,
                      fingerprint: "ab12cd34ef56ab78cd90ef12ab34cd56")
        return s
    }
}
