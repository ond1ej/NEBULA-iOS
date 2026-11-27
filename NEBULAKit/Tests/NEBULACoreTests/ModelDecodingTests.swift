import Foundation
import Testing
@testable import NEBULACore

@Suite("Wire models")
struct ModelDecodingTests {
    @Test func messagesWithBothAttachmentForms() throws {
        let json = #"""
        {"id":"m1","conversation_id":"c1","agent_id":"a1","task_id":"t1","role":"assistant","channel":"web",
         "content":"**Hotovo**","attachments":["artifacts/a1/shot.png",{"id":"att1","name":"voice.m4a","kind":"voice",
         "mime":"audio/mp4","size":12,"status":"ready","created_at":1.0,"extracted":{"transcript":{"ok":true,"text":"ahoj"}}}],
         "created_at":1700000000.5,"client_id":null,"task":{"id":"t1","state":"COMPLETED","started_at":1,"finished_at":2,"failure_reason":null}}
        """#
        let m = try NJSON.decoder().decode(Message.self, from: Data(json.utf8))
        #expect(m.attachments.count == 2)
        if case .file(let a) = m.attachments[1] { #expect(a.transcript == "ahoj" && a.isAudio) } else { Issue.record("file") }
        #expect(m.task?.state == "COMPLETED")
    }

    @Test func conversationAndUnknownFieldsAreIgnored() throws {
        let json = #"""
        {"id":"c1","agent_id":"a1","agent_name":"Jarvis","agent_status":"READY","title":"Teams","created_at":1,
         "updated_at":2,"last_message_at":3,"last_message":{"role":"user","content":"hi","created_at":3},
         "unread_count":2,"archived":false,"is_default":true,"running_task":{"id":"t","state":"EXECUTING"},"future":42}
        """#
        let c = try NJSON.decoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(c.sortDate == 3 && c.unreadCount == 2 && c.runningTask?.state == "EXECUTING")
    }

    @Test func signInSessionDecodes() throws {
        let json = #"""
        {"id":"as_1","state":"PASSWORD_REQUIRED","agent_id":"a","agent_name":"Jarvis","task_id":"t","conversation_id":null,
         "requested_origin":"https://teams.microsoft.com","verified_origin":"https://login.microsoftonline.com","site":"x",
         "allowed_origins":[],"step":"password","step_seq":3,"confidence":"HIGH","flags":[],"auth_method":null,
         "error_code":null,"created_at":1,"updated_at":2,"expires_at":3,"completed_at":null,
         "attempts":{"credentials":0,"codes":0,"max_credentials":3,"max_codes":3},"saved_to_vault":false,
         "request":{"id":"r1","type":"credentials","seq":3,"expires_at":9,"step":"password",
           "fields":[{"id":"f1","role":"password","input":"password","length":null,"charset":null}],
           "otp":null,"confidence":"HIGH","flags":[],"review_required":false,"error":null,"requirement":"PASSWORD_REQUIRED",
           "notes":["passkey_cancelled","chose_password"],"trust":{"level":"GREEN","reasons":[],"provider":"Microsoft","hard":false},
           "alternatives":[],"page_origin":"https://login.microsoftonline.com",
           "vault":{"state":"locked","can_save":true,"can_unlock":true,"reason":null},"save_intent":"vault","local":false,
           "fresh":false,"remote_submission":true,"pin_configured":true,"pin_locked_until":null,
           "pin_required_for":["credentials"],"accounts":[]}}
        """#
        let s = try NJSON.decoder().decode(SignInSession.self, from: Data(json.utf8))
        #expect(s.needsOwner && s.request?.fields.first?.isSecret == true && s.request?.trust?.provider == "Microsoft")
    }

    @Test func taskStates() {
        #expect(NText.taskState("WAITING_APPROVAL") == "Waiting for approval")
        #expect(NText.stage("model_request") == "Thinking")
    }
}
