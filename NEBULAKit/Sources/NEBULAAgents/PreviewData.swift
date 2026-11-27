import Foundation
import NEBULACore
import NEBULANetwork

/// Sample data for SwiftUI previews (decoded from JSON literals in the server's wire format).
@MainActor
enum PreviewData {
    static let now = Date().timeIntervalSince1970

    static var agents: [Agent] {
        Remodel.decode(json: """
        [
          {"id": "a1", "name": "Researcher", "description": "Finds and summarizes sources on a topic.", "state": "ACTIVE",
           "provider_id": "anthropic", "model_id": "claude-sonnet-4-5", "permission_level": "STANDARD",
           "desktop_resolution": "1280x800", "last_active_at": \(now - 30), "created_at": \(now - 86400 * 20),
           "current_task": {"id": "t1", "state": "EXECUTING"},
           "config": {"avatar": {"kind": "icon", "value": "search"}, "sign_in_assistance": true, "memory_auto_save": true}},
          {"id": "a2", "name": "Accountant", "description": "Invoices and statements.", "state": "READY",
           "provider_id": "openai", "model_id": "gpt-5", "permission_level": "ADVANCED",
           "last_active_at": \(now - 3600 * 5), "created_at": \(now - 86400 * 40),
           "config": {"avatar": {"kind": "emoji", "value": "🧾"}}},
          {"id": "a3", "name": "Web Tester", "state": "SLEEP", "provider_id": "anthropic", "model_id": "claude-haiku-4-5",
           "permission_level": "STANDARD", "last_active_at": \(now - 86400 * 3), "created_at": \(now - 86400 * 60),
           "config": {"avatar": {"kind": "initials", "value": "WT"}}},
          {"id": "a4", "name": "Mail Clerk", "state": "ERROR", "last_error": "Could not start the desktop (Xvfb)",
           "provider_id": "anthropic", "model_id": "claude-sonnet-4-5", "created_at": \(now - 86400 * 2),
           "config": {"avatar": {"kind": "icon", "value": "mail"}}}
        ]
        """) ?? []
    }

    static var tasks: [AgentTask] {
        Remodel.decode(json: """
        [
          {"id": "t1", "agent_id": "a1", "agent_name": "Researcher", "state": "EXECUTING", "current_step": 4,
           "max_steps": 40, "prompt": "Find the three most recent studies on heat pumps in apartment buildings and summarize them.",
           "created_at": \(now - 95), "started_at": \(now - 90),
           "steps": [
             {"id": "s1", "seq": 1, "tool_type": "web_search", "result_status": "ok", "result_summary": "8 hits", "elapsed_ms": 1840, "created_at": \(now - 80)},
             {"id": "s2", "seq": 2, "tool_type": "browser_navigate", "result_status": "ok", "result_summary": "Opened example.com", "elapsed_ms": 2310, "created_at": \(now - 60)},
             {"id": "s3", "seq": 3, "tool_type": "browser_observe", "result_status": "ok", "elapsed_ms": 640, "created_at": \(now - 40)},
             {"id": "s4", "seq": 4, "tool_type": "files_write", "result_status": "denied", "result_summary": "approval denied", "elapsed_ms": 12, "created_at": \(now - 20)}
           ]},
          {"id": "t2", "agent_id": "a1", "state": "COMPLETED", "prompt": "Summarize today's energy news.",
           "created_at": \(now - 7200), "started_at": \(now - 7190), "finished_at": \(now - 6900),
           "result": {"summary": "Three main stories: …"}, "steps": []},
          {"id": "t3", "agent_id": "a1", "state": "FAILED", "prompt": "Sign in to the supplier portal and download the invoice.",
           "failure_reason": "Signing in needs an SMS code that was not entered in time.",
           "created_at": \(now - 86400), "started_at": \(now - 86390), "finished_at": \(now - 86000),
           "steps": [
             {"id": "s5", "seq": 1, "tool_type": "browser_navigate", "result_status": "ok", "elapsed_ms": 2100, "created_at": \(now - 86380)},
             {"id": "s6", "seq": 2, "tool_type": "smart_sign_in", "result_status": "error", "result_summary": "timeout waiting for the owner", "elapsed_ms": 300000, "created_at": \(now - 86000)}
           ]}
        ]
        """) ?? []
    }

    static var options: ComposerOptions? {
        Remodel.decode(json: """
        {"providers": [{"id": "anthropic", "name": "Anthropic", "state": "Connected", "connected": true},
                       {"id": "openai", "name": "OpenAI", "state": "Connected", "connected": true},
                       {"id": "gemini", "name": "Google Gemini", "state": "Disconnected", "connected": false}],
         "capabilities": [
           {"id": "browser", "label": "Browser", "default": true, "requires_level": "STANDARD"},
           {"id": "web_research", "label": "Web research", "default": true, "requires_level": "STANDARD"},
           {"id": "files", "label": "Files", "default": true, "requires_level": "STANDARD"},
           {"id": "terminal", "label": "Terminal", "default": false, "requires_level": "ADVANCED"},
           {"id": "desktop", "label": "Desktop control", "default": false, "requires_level": "STANDARD"}],
         "memory": {"default": true},
         "extra_skills": [],
         "levels": [{"id": "READ_ONLY"}, {"id": "STANDARD"}, {"id": "ADVANCED"}],
         "default_level": "STANDARD",
         "vault": {"options": [{"id": "none", "default": true}, {"id": "ask"}]},
         "avatar": {"kinds": ["emoji", "initials", "icon"], "icons": ["robot", "spark", "brain", "code", "search", "chart", "briefcase", "globe", "shield", "book", "bolt", "star", "mail", "calendar", "music", "camera"]},
         "name_rules": {"max": 64}, "existing_names": ["Researcher", "Accountant"],
         "default_instructions": "Be concise and accurate.",
         "limits": {"instructions_max": 4000, "description_max": 1000},
         "advanced": {"default_resolution": "1280x800"}}
        """)
    }

    static var models: [ModelChoice] {
        Remodel.decode(json: """
        [{"id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5", "supports_tools": true},
         {"id": "claude-haiku-4-5", "name": "Claude Haiku 4.5", "supports_tools": true},
         {"id": "claude-embed", "name": "Embeddings", "supports_tools": false}]
        """) ?? []
    }

    static func client() -> APIClient {
        APIClient(baseURL: URL(string: "https://nebula.invalid") ?? URL(fileURLWithPath: "/"), tokens: nil)
    }

    static func store() -> AgentsStore {
        let s = AgentsStore(api: client(), hub: EventHub(), gate: OwnerGate())
        let t = tasks
        s.seedPreview(agents: agents,
                      stages: ["a1": AgentStage(taskID: "t1", stage: "thinking", elapsedMs: 12_000)],
                      tasks: ["a1": t.map { var x = $0; x.steps = nil; return x }],
                      details: t)
        s.seedPreviewComposer(options: options, models: ["anthropic": models, "openai": models])
        return s
    }

    static func emptyStore() -> AgentsStore {
        let s = AgentsStore(api: client(), hub: EventHub(), gate: OwnerGate())
        s.offline = true
        return s
    }
}
