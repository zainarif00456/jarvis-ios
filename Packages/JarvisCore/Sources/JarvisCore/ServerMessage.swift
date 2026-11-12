import Foundation

/// Everything the server can send on `/ws/session`, decoded tolerantly: an unknown `type` becomes
/// `.unknown`, a known type whose body does not decode becomes `.malformed`. Neither ever throws.
public enum ServerMessage: Equatable, Sendable {
    case welcome(WelcomeInfo)
    case status(StatusInfo)
    case turnStarted(turnId: String, kind: String?, agent: String?, voice: Bool)
    case textDelta(turnId: String, text: String)
    case toolStarted(turnId: String, callId: String?, name: String, args: JSONValue?)
    case toolFinished(turnId: String, callId: String?, name: String?, ok: Bool, status: String?)
    case turnDone(TurnDone)
    case turnFailed(turnId: String?, message: String)
    case turnInterrupted(turnId: String?)
    case turnQueued(position: Int)
    case modelSwitched(model: String, reason: String?)
    case taskUpdate(TaskInfo)
    case agentMessage(AgentMessage)
    case approvalRequest(ApprovalInfo)
    case approvalResolved(id: String, status: String?, by: String?)
    case callStarted(resumed: Bool)
    case callEnded(reason: String?)
    case voiceState(String)
    case voicePartial(String)
    case voiceFinal(String)
    case voiceStop
    case voiceError(text: String, recoverable: Bool)
    case ttsStart(turnId: String?, text: String?, display: String?, speaker: String?)
    case ttsEnd(turnId: String?)
    case execStart(ExecStart)
    case execEnd(ExecEnd)
    case screenCmd(ScreenCommand)
    case briefingRequest([BriefingRun])
    case briefingCleared(ids: [String])
    case announcement(text: String)
    case userMessage(text: String, device: String?)
    case commandResult(line: String, ok: Bool, text: String)
    case fileAdded(FileInfo)
    case fileRemoved(ids: [String])
    case schedules(ScheduleState)
    case cameras([CameraInfo])
    case cameraStatus(id: String, state: String?, detail: String?, viewers: Int?)
    case mediaAdded(MediaItem)
    case mediaChanged(MediaItem)
    case recordingUpdate([RecordingCard])
    case terminalOpened(TerminalInfo)
    case terminalFocus(id: String)
    case terminalClosed(id: String)
    case sessionReset(number: Int?, reason: String?)
    case agents(AgentsStatus)
    case notice(level: String?, text: String)
    case error(text: String)
    case pong
    case unknown(type: String)
    case malformed(type: String)

    public struct TurnDone: Equatable, Sendable {
        public var turnId: String
        public var text: String
        public var model: String?
        public var costUsd: Double?
        public var toolsUsed: [String]
    }
    public struct AgentMessage: Equatable, Sendable {
        public var persona: String
        public var name: String?
        public var text: String
        public var final: Bool
        public var taskId: String?
        public var spoken: Bool
    }
}

public enum ServerMessageDecoder {
    public static func decode(_ data: Data) -> ServerMessage? {
        guard let root = JSONValue.parse(data), case .object = root, let type = root["type"]?.string else { return nil }
        return decode(type: type, root: root, data: data)
    }

    public static func decode(_ text: String) -> ServerMessage? { decode(Data(text.utf8)) }

    static func decode(type: String, root: JSONValue, data: Data) -> ServerMessage {
        let dec = JSONDecoder()
        func str(_ k: String) -> String? { root[k]?.string }
        func typed<T: Decodable>(_ key: String?, _ t: T.Type) -> T? {
            if let key = key {
                guard let v = root[key], let d = try? JSONEncoder().encode(v) else { return nil }
                return try? dec.decode(T.self, from: d)
            }
            return try? dec.decode(T.self, from: data)
        }
        switch type {
        case "welcome":
            var w = WelcomeInfo()
            w.device = str("device")
            w.serverVersion = root["server"]?["version"]?.string
            w.status = typed("status", StatusInfo.self)
            w.tasks = lossy(root["tasks"], TaskInfo.self)
            w.approvals = lossy(root["approvals"], ApprovalInfo.self)
            w.files = lossy(root["files"], FileInfo.self)
            w.cameras = lossy(root["cameras"], CameraInfo.self)
            w.terminals = lossy(root["terminals"], TerminalInfo.self)
            w.history = lossy(root["history"], HistoryItem.self)
            w.schedules = typed("schedules", ScheduleState.self)
            w.agents = typed("agents", AgentsStatus.self)
            w.busy = root["busy"]?.bool ?? false
            w.sessionNumber = root["session"]?["number"]?.int
            return .welcome(w)
        case "status":
            return typed(nil, StatusInfo.self).map { .status($0) } ?? .malformed(type: type)
        case "turn_started":
            guard let id = str("turn_id") else { return .malformed(type: type) }
            return .turnStarted(turnId: id, kind: str("kind"), agent: str("agent"), voice: root["voice"]?.bool ?? false)
        case "text_delta":
            guard let id = str("turn_id"), let t = str("text") else { return .malformed(type: type) }
            return .textDelta(turnId: id, text: t)
        case "tool_started":
            guard let id = str("turn_id") else { return .malformed(type: type) }
            return .toolStarted(turnId: id, callId: str("call_id"), name: str("name") ?? "tool", args: root["args"])
        case "tool_finished":
            guard let id = str("turn_id") else { return .malformed(type: type) }
            return .toolFinished(turnId: id, callId: str("call_id"), name: str("name"), ok: root["ok"]?.bool ?? (str("status") == "done"), status: str("status"))
        case "turn_done":
            guard let id = str("turn_id") else { return .malformed(type: type) }
            return .turnDone(.init(turnId: id, text: str("text") ?? "", model: str("model"), costUsd: root["cost_usd"]?.double,
                                   toolsUsed: root["tools_used"]?.array?.compactMap { $0.string } ?? []))
        case "turn_failed":
            return .turnFailed(turnId: str("turn_id"), message: str("message") ?? str("text") ?? "The turn failed.")
        case "turn_interrupted": return .turnInterrupted(turnId: str("turn_id"))
        case "turn_queued": return .turnQueued(position: root["position"]?.int ?? 0)
        case "model_switched": return .modelSwitched(model: str("model") ?? "", reason: str("reason"))
        case "task_update":
            return typed("task", TaskInfo.self).map { .taskUpdate($0) } ?? .malformed(type: type)
        case "agent_message":
            guard let text = str("text") else { return .malformed(type: type) }
            return .agentMessage(.init(persona: str("persona") ?? "agent", name: str("name"), text: text,
                                       final: root["final"]?.bool ?? false, taskId: str("task_id"), spoken: root["spoken"]?.bool ?? false))
        case "approval_request":
            return typed("approval", ApprovalInfo.self).map { .approvalRequest($0) } ?? .malformed(type: type)
        case "approval_resolved":
            guard let id = str("id") else { return .malformed(type: type) }
            return .approvalResolved(id: id, status: str("status"), by: str("by"))
        case "call_started": return .callStarted(resumed: root["resumed"]?.bool ?? false)
        case "call_ended": return .callEnded(reason: str("reason"))
        case "voice_state": return .voiceState(str("state") ?? "idle")
        case "voice_partial": return .voicePartial(str("text") ?? "")
        case "voice_final": return .voiceFinal(str("text") ?? "")
        case "voice_stop": return .voiceStop
        case "voice_error": return .voiceError(text: str("text") ?? "Voice error.", recoverable: root["recoverable"]?.bool ?? false)
        case "tts_start": return .ttsStart(turnId: str("turn_id"), text: str("text"), display: str("display"), speaker: str("speaker"))
        case "tts_end": return .ttsEnd(turnId: str("turn_id"))
        case "exec_start":
            guard let id = str("id") else { return .malformed(type: type) }
            let kind = str("kind") ?? "tool"
            return .execStart(ExecStart(id: id, who: str("who") ?? "jarvis", kind: kind, title: str("title") ?? kind, parent: str("parent"), wide: root["detail"]?["wide"]?.bool ?? false))
        case "exec_end":
            guard let id = str("id") else { return .malformed(type: type) }
            return .execEnd(ExecEnd(id: id, ok: root["ok"]?.bool ?? true, ms: root["ms"]?.int, result: ExecResult.parse(root["result"])))
        case "screen_cmd":
            guard let cmd = str("cmd_id"), let action = str("action") else { return .malformed(type: type) }
            return .screenCmd(ScreenCommand(cmdId: cmd, action: action, target: str("target"), args: root["args"] ?? .object([:])))
        case "briefing_request":
            let runs = (root["runs"]?.array ?? []).compactMap { r -> BriefingRun? in
                guard let id = r["id"]?.string else { return nil }
                return BriefingRun(id: id, title: r["title"]?.string ?? "A briefing", priority: r["priority"]?.string ?? "normal", preview: r["preview"]?.string ?? "", failed: r["failed"]?.bool ?? false)
            }
            return .briefingRequest(runs)
        case "briefing_cleared": return .briefingCleared(ids: root["ids"]?.array?.compactMap { $0.string } ?? [])
        case "announcement": return .announcement(text: str("text") ?? "")
        case "user_message": return .userMessage(text: str("text") ?? "", device: str("device"))
        case "command_result": return .commandResult(line: str("line") ?? "", ok: root["ok"]?.bool ?? true, text: str("text") ?? "")
        case "file_added": return typed("file", FileInfo.self).map { .fileAdded($0) } ?? .malformed(type: type)
        case "file_removed": return .fileRemoved(ids: root["ids"]?.array?.compactMap { $0.string } ?? [])
        case "schedules": return typed(nil, ScheduleState.self).map { .schedules($0) } ?? .malformed(type: type)
        case "cameras": return .cameras(lossy(root["cameras"], CameraInfo.self))
        case "camera_status":
            guard let id = str("id") else { return .malformed(type: type) }
            return .cameraStatus(id: id, state: str("state"), detail: str("detail"), viewers: root["viewers"]?.int)
        case "media_added": return typed("media", MediaItem.self).map { .mediaAdded($0) } ?? .malformed(type: type)
        case "media_changed": return typed("media", MediaItem.self).map { .mediaChanged($0) } ?? .malformed(type: type)
        case "recording_update": return .recordingUpdate(lossy(root["recordings"], RecordingCard.self))
        case "terminal_opened": return typed("terminal", TerminalInfo.self).map { .terminalOpened($0) } ?? .malformed(type: type)
        case "terminal_focus": return .terminalFocus(id: str("id") ?? "")
        case "terminal_closed": return .terminalClosed(id: str("id") ?? "")
        case "session_reset": return .sessionReset(number: root["number"]?.int, reason: str("reason"))
        case "agents": return typed(nil, AgentsStatus.self).map { .agents($0) } ?? .malformed(type: type)
        case "notice": return .notice(level: str("level"), text: str("text") ?? "")
        case "error": return .error(text: str("message") ?? str("text") ?? "The server reported an error.")
        case "pong": return .pong
        default: return .unknown(type: type)
        }
    }

    static func lossy<T: Decodable>(_ value: JSONValue?, _ t: T.Type) -> [T] {
        guard let items = value?.array else { return [] }
        let dec = JSONDecoder()
        let enc = JSONEncoder()
        return items.compactMap { item in
            guard let d = try? enc.encode(item) else { return nil }
            return try? dec.decode(T.self, from: d)
        }
    }
}

/// Messages the app sends. Encoded with the exact field names the server's pydantic models accept
/// (`extra="forbid"`: an unexpected field would be rejected, so only the documented ones are sent).
public enum ClientMessage: Equatable, Sendable {
    case hello(client: String)
    case userMessage(text: String, attachments: [String])
    case interrupt
    case approval(id: String, approve: Bool)
    case cancelTask(id: String)
    case stopAll
    case command(line: String)
    case ping
    case presence(visible: Bool)
    case callStart(manual: Bool)
    case callEnd
    case agentSelect(String)
    case terminalOpen(cwd: String?)
    case terminalClose(id: String)
    case voicePlayback(event: String, underruns: Int, gapMs: Int)
    case screenState(ScreenSnapshot)
    case screenAck(cmdId: String, ok: Bool, error: String, detail: String, state: ScreenSnapshot?)
    case execAction(handle: String, action: String, req: String?)
    case briefingAccept(textOnly: Bool)
    case briefingDismiss(ids: [String])

    public func json() -> String {
        var o: [String: JSONValue]
        switch self {
        case .hello(let c): o = ["type": .string("hello"), "client": .string(String(c.prefix(60)))]
        case .userMessage(let t, let a):
            o = ["type": .string("user_message"), "text": .string(t)]
            if !a.isEmpty { o["attachments"] = .array(a.prefix(10).map { .string($0) }) }
        case .interrupt: o = ["type": .string("interrupt")]
        case .approval(let id, let ok): o = ["type": .string("approval"), "id": .string(id), "approve": .bool(ok)]
        case .cancelTask(let id): o = ["type": .string("cancel_task"), "task_id": .string(id)]
        case .stopAll: o = ["type": .string("stop_all")]
        case .command(let l): o = ["type": .string("command"), "line": .string(l)]
        case .ping: o = ["type": .string("ping")]
        case .presence(let v): o = ["type": .string("presence"), "visible": .bool(v)]
        case .callStart(let m): o = ["type": .string("call_start"), "manual": .bool(m)]
        case .callEnd: o = ["type": .string("call_end")]
        case .agentSelect(let a): o = ["type": .string("agent_select"), "agent": .string(a)]
        case .terminalOpen(let cwd):
            o = ["type": .string("terminal_open")]
            if let cwd = cwd, !cwd.isEmpty { o["cwd"] = .string(cwd) }
        case .terminalClose(let id): o = ["type": .string("terminal_close"), "id": .string(id)]
        case .voicePlayback(let e, let u, let g):
            o = ["type": .string("voice_playback"), "event": .string(e), "underruns": .number(Double(max(0, u))), "gap_ms": .number(Double(max(0, g)))]
        case .screenState(let snap):
            o = snap.bodyFields; o["type"] = .string("screen_state")
        case .screenAck(let id, let ok, let err, let detail, let state):
            o = ["type": .string("screen_ack"), "cmd_id": .string(String(id.prefix(64))), "ok": .bool(ok),
                 "error": .string(String(err.prefix(500))), "detail": .string(String(detail.prefix(300)))]
            if let st = state { o["state"] = .object(st.bodyFields) }
        case .execAction(let h, let a, let req):
            o = ["type": .string("exec_action"), "handle": .string(h), "action": .string(a)]
            if let r = req { o["req"] = .string(String(r.prefix(40))) }
        case .briefingAccept(let t): o = ["type": .string("briefing_accept"), "text_only": .bool(t)]
        case .briefingDismiss(let ids): o = ["type": .string("briefing_dismiss"), "ids": .array(ids.prefix(50).map { .string($0) })]
        }
        return JSONValue.object(o).serialized()
    }

    /// True for messages that may be sent at any time, even with no welcome yet.
    public var isKeepalive: Bool { if case .ping = self { return true }; return false }
}
