import XCTest
@testable import HermesIOSCore

final class SettingsCatalogTests: XCTestCase {
    func testExplicitFieldsWinOverPrefixesAndLongestPrefixWins() {
        XCTAssertEqual(SettingsCatalog.pageID(for: "terminal.cwd"), "workspace.projects")
        XCTAssertEqual(SettingsCatalog.pageID(for: "terminal.backend"), "advanced.terminal")
        XCTAssertEqual(SettingsCatalog.pageID(for: "auxiliary.compression.timeout"), "memory.context")
        XCTAssertEqual(SettingsCatalog.pageID(for: "auxiliary.vision.model"), "model.auxiliary")
        XCTAssertEqual(SettingsCatalog.pageID(for: "agent.service_tier"), "model.main")
        XCTAssertEqual(SettingsCatalog.pageID(for: "voice.auto_tts"), "voice.speech")
        XCTAssertEqual(SettingsCatalog.pageID(for: "voice.barge_in"), "voice.conversation")
        XCTAssertEqual(SettingsCatalog.pageID(for: "checkpoints.enabled"), "safety.checkpoints")
        XCTAssertNil(SettingsCatalog.pageID(for: "discord.require_mention"))
    }

    func testEveryKeyIsReachable() {
        let keys = ["model", "approvals.mode", "discord.token_env", "display.skin", "paste_collapse_threshold", "tts.edge.voice"]
        let paged = SettingsCatalog.pages.flatMap { SettingsCatalog.keys(on: $0.id, from: keys) }
        let others = SettingsCatalog.otherGroups(keys).flatMap(\.keys)
        XCTAssertEqual(Set(paged + others), Set(keys))
        XCTAssertEqual(Set(paged).intersection(others), [])
        XCTAssertTrue(SettingsCatalog.otherGroups(keys).contains { $0.id == "general" && $0.keys == ["paste_collapse_threshold"] })
    }

    func testDeclaredFieldsComeFirstOnAPage() {
        let keys = SettingsCatalog.keys(on: "voice.conversation", from: ["voice.silence_duration", "voice.client_direct", "voice.voice_chat_mode", "voice.max_recording_seconds"])
        XCTAssertEqual(keys, ["voice.voice_chat_mode", "voice.max_recording_seconds", "voice.client_direct", "voice.silence_duration"])
    }

    func testKinds() {
        XCTAssertEqual(SettingsCatalog.kind(key: "stt.streaming", schema: ["type": "boolean"], value: false, defaultValue: false), .toggle)
        XCTAssertEqual(SettingsCatalog.kind(key: "voice.stop_phrases", schema: ["type": "list"], value: ["stop"], defaultValue: ["stop"]), .stringList)
        XCTAssertEqual(SettingsCatalog.kind(key: "fallback_providers", schema: ["type": "list"], value: [], defaultValue: []), .structured(isArray: true))
        XCTAssertEqual(SettingsCatalog.kind(key: "delegation.api_key", schema: ["type": "string"], value: "x", defaultValue: ""), .secret)
        XCTAssertEqual(SettingsCatalog.kind(key: "agent.max_turns", schema: ["type": "string"], value: .null, defaultValue: .null), .loose)
        XCTAssertEqual(SettingsCatalog.kind(key: "approvals.smart_policy", schema: ["type": "string"], value: "", defaultValue: ""), .text(long: true))
        if case .choice(let options, let free, _) = SettingsCatalog.kind(key: "tts.openai.voice", schema: ["type": "string"], value: "nova", defaultValue: "alloy") {
            XCTAssertTrue(free); XCTAssertTrue(options.contains("nova"))
        } else { XCTFail("Expected a choice") }
        if case .choice(let options, false, _) = SettingsCatalog.kind(key: "auxiliary.vision.reasoning_effort", schema: ["type": "string"], value: "", defaultValue: "") {
            XCTAssertEqual(options.first, "")
        } else { XCTFail("Expected reasoning options") }
    }

    func testValueParsing() {
        XCTAssertEqual(SettingsCatalog.number("1,5"), 1.5)
        XCTAssertNil(SettingsCatalog.number("abc"))
        XCTAssertEqual(SettingsCatalog.looseValue("90"), .number(90))
        XCTAssertEqual(SettingsCatalog.looseValue(""), .null)
        XCTAssertEqual(SettingsCatalog.looseValue("auto"), .string("auto"))
        XCTAssertTrue(SettingsCatalog.isModified(value: 2, defaultValue: 3))
        XCTAssertFalse(SettingsCatalog.isModified(value: 3, defaultValue: 3))
        XCTAssertFalse(SettingsCatalog.isModified(value: 3, defaultValue: nil))
    }

    func testVoiceFieldsFollowTheSelectedProvider() {
        let config: JSONValue = ["tts": ["provider": "openai"], "stt": ["enabled": true, "provider": ""]]
        XCTAssertTrue(SettingsCatalog.voiceFieldVisible("tts.openai.voice", config: config))
        XCTAssertFalse(SettingsCatalog.voiceFieldVisible("tts.edge.voice", config: config))
        XCTAssertTrue(SettingsCatalog.voiceFieldVisible("stt.local.model", config: config))
        XCTAssertTrue(SettingsCatalog.voiceFieldVisible("tts.streaming.min_len", config: config))
        XCTAssertEqual(SettingsCatalog.options(for: "tts.openai.voice", base: ["alloy", "marin"], current: "alloy", config: ["tts": ["openai": ["model": "tts-1"]]]), ["alloy"])
    }

    func testListEditingAndFallbacks() {
        XCTAssertEqual(StringListEditing.adding(" git status ", to: ["ls"]), ["ls", "git status"])
        XCTAssertEqual(StringListEditing.adding("ls", to: ["ls"]), ["ls"])
        XCTAssertEqual(StringListEditing.moving(from: [0], to: 3, in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(StringListEditing.removing(at: [1], from: ["a", "b", "c"]), ["a", "c"])
        let routes = FallbackRoute.parse([["provider": "openrouter", "model": "x", "base_url": "http://gw"], "nous/Hermes"])
        XCTAssertEqual(routes.map(\.provider), ["openrouter", "nous"])
        XCTAssertEqual(FallbackRoute.encode(routes + [FallbackRoute(provider: "", model: "")]).array.count, 2)
        XCTAssertEqual(FallbackRoute.encode(routes).array.first?["base_url"], "http://gw")
    }

    func testSearchIgnoresAccentsAndMatchesLabels() {
        XCTAssertTrue(SettingsCatalog.matches("synthese vocale", key: "tts.provider", description: nil))
        XCTAssertTrue(SettingsCatalog.matches("barge", key: "voice.barge_in", description: nil))
        XCTAssertFalse(SettingsCatalog.matches("telegram", key: "voice.barge_in", description: nil))
        XCTAssertNil(SettingsCatalog.description("browser.headless_x", schema: ["description": "Browser → Headless X"]))
    }
}
