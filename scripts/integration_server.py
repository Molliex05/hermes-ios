#!/usr/bin/env python3
"""Real, unmodified Hermes serve + a deterministic local model for integration tests.

Run with Python from a venv containing the pinned upstream Hermes checkout.
Only the inference endpoint is a fixture. Auth, profiles, sessions, persistence,
WebSocket framing, replay and Bot Mode execute upstream code.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLY = "Bonjour depuis Hermes. Votre conversation reste fluide, même après une interruption du réseau. Les profils, la mémoire et les outils restent entièrement gérés par votre agent. Voilà, le fil est retrouvé."


class Model(BaseHTTPRequestHandler):
    live_fixture = None

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/v1beta/voices"):
            # Fake Gemini Voices API (gemini-voix plugin fixture): one stored Voice design voice.
            assert self.headers.get("x-goog-api-key") == "hermes-ios-gemini-fixture", "Gemini key must travel in the header"
            from urllib.parse import parse_qs, urlparse
            query = parse_qs(urlparse(self.path).query)
            voices = [{"id": "voice_fixture123", "display_name": "Ma voix québécoise", "language_code": "fr-CA", "type": "prompted"}] if "prompted" in query.get("type", []) else []
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps({"voices": voices}).encode())
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"object": "list", "data": [{"id": "hermes-ios-fixture", "object": "model"}]}).encode())

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/v1/audio/transcriptions":
            self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
            self.wfile.write("Bonjour Hermes, résume mon projet.".encode())
            return
        body = json.loads(raw)
        if self.path == "/v1beta/interactions":
            # Fake Gemini 3.8 Interactions API: exact request shape, then WAV (unary) or SSE PCM (stream).
            assert self.headers.get("x-goog-api-key") == "hermes-ios-gemini-fixture", "Gemini key must travel in the header"
            assert body["model"] == "gemini-3.8-flash-lite-tts", body["model"]
            assert body["generation_config"]["speech_config"] == [{"voice": "voice_fixture123"}], body["generation_config"]
            assert body["input"][0]["type"] == "user_input" and body["input"][0]["content"][0]["text"], body["input"]
            print("Fixture Gemini TTS voice=" + body["generation_config"]["speech_config"][0]["voice"] + " stream=" + str(bool(body.get("stream"))), flush=True)
            import base64, io, wave
            pcm = b"\x00\x00" * 4800  # 0.2 s at 24 kHz
            if body.get("stream"):
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
                self.wfile.write(b'data: {"event_type": "interaction.start"}\n\n')
                for _ in range(3):
                    event = {"event_type": "step.delta", "delta": {"type": "audio", "data": base64.b64encode(pcm).decode()}}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode()); self.wfile.flush()
                self.wfile.write(b'data: {"event_type": "interaction.complete"}\n\n')
            else:
                output = io.BytesIO()
                with wave.open(output, "wb") as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(pcm)
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"steps": [{"type": "model_output", "content": [{"type": "audio", "data": base64.b64encode(output.getvalue()).decode()}]}]}).encode())
            return
        if self.path == "/v1/live/sessions" and self.live_fixture:
            response = self.live_fixture.answer(body)
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            return
        if self.path == "/v1/audio/speech":
            import io, wave
            output = io.BytesIO()
            with wave.open(output, "wb") as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                wav.writeframes(b"\x00\x00" * 72000)
            self.send_response(200); self.send_header("Content-Type", "audio/wav"); self.end_headers()
            self.wfile.write(b"\x00\x00" * 72000 if body.get("response_format") == "pcm" else output.getvalue())
            print("Fixture TTS voice: " + str(body.get("voice")), flush=True)
            return
        messages = body.get("messages", [])
        last_user = max((i for i,m in enumerate(messages) if m.get("role") == "user"), default=-1)
        interactive = last_user >= 0 and "HERMES_IOS_REQUEST_TEST" in str(messages[last_user].get("content", "")) and not any(m.get("role") == "tool" for m in messages[last_user+1:])
        tool_background = last_user >= 0 and "HERMES_IOS_TOOL_BACKGROUND_TEST" in str(messages[last_user].get("content", "")) and not any(m.get("role") == "tool" for m in messages[last_user+1:])
        notify_tool = last_user >= 0 and "HERMES_IOS_NOTIFY_TEST" in str(messages[last_user].get("content", "")) and not any(m.get("role") == "tool" for m in messages[last_user+1:])
        if interactive or tool_background or notify_tool:
            arguments = json.dumps({"questions": [{"question": "Choisir une couleur", "choices": ["Bleu", "Vert"]}, {"question": "Un détail à ajouter ?"}]})
            tool = {"id": "fixture-clarify", "type": "function", "function": {"name": "clarify", "arguments": arguments}}
            if notify_tool:
                tool = {"id": "fixture-notify", "type": "function", "function": {"name": "tool_call", "arguments": json.dumps({"calls": [{"name": "ios_notify", "arguments": {"message": "Rapport prêt : **42** erreurs corrigées", "subtitle": "Audit", "open_conversation": True}}]})}}   # plugin tools are deferred behind Tool Search in Hermes 0.21.7
            if tool_background:
                tool = {"id": "fixture-terminal", "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": "sleep 35; echo HERMES_BACKGROUND_TOOL_DONE", "timeout": 60})}}
            self.send_response(200)
            if body.get("stream"):
                self.send_header("Content-Type", "text/event-stream"); self.end_headers()
                chunk = {"id":"interactive", "object":"chat.completion.chunk", "created":int(time.time()), "model":"hermes-ios-fixture", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0, **tool}]},"finish_reason":None}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n')
            else:
                self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps({"id":"interactive", "object":"chat.completion", "created":int(time.time()), "model":"hermes-ios-fixture", "choices":[{"index":0,"message":{"role":"assistant", "content":None,"tool_calls":[tool]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20}}).encode())
            return
        self.send_response(200)
        slow = any("HERMES_IOS_BACKGROUND_TEST" in str(m.get("content", "")) for m in body.get("messages", []) if m.get("role") == "user")
        markdown = any("HERMES_IOS_MARKDOWN_TEST" in str(m.get("content", "")) for m in body.get("messages", []) if m.get("role") == "user")
        reply = "Premiers mots reçus.\n\n## Une réponse structurée\n\nDu **gras**, de l’*italique* et du `code inline`.\n\n1. Première étape\n2. Deuxième étape\n\n> Une citation lisible.\n\n| Option | État |\n| --- | --- |\n| Streaming | Actif |\n| Markdown | Natif |\n\n```swift\nlet message = \"Bonjour\"\nprint(message)\n```\n\nRéponse terminée." if markdown else REPLY
        if body.get("stream"):
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for word in reply.split(" "):
                chunk = {"id": "test", "object": "chat.completion.chunk", "created": int(time.time()), "model": "hermes-ios-fixture", "choices": [{"index": 0, "delta": {"content": word + " "}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(1.0 if slow else 0.4 if markdown else 0.16)
            self.wfile.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        else:
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"id": "test", "object": "chat.completion", "created": int(time.time()), "model": "hermes-ios-fixture", "choices": [{"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 35, "total_tokens": 45}}).encode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--port", type=int, default=19119)
    parser.add_argument("--model-port", type=int, default=19220)
    parser.add_argument("--push-plugin", action="store_true")
    parser.add_argument("--live-fixture", action="store_true")
    parser.add_argument("--gemini-voix", action="store_true", help="Install server/hermes-gemini-voix with a loopback Gemini 3.8 fixture")
    parser.add_argument("--upstream-root", type=Path, help="Optional official checkout to test without modifying an installed environment")
    args = parser.parse_args()
    home = args.home.resolve()
    if home.exists() and any(home.iterdir()):
        raise SystemExit("Use a new, empty --home directory; never point at your own Hermes home.")
    home.mkdir(parents=True, exist_ok=True)
    import yaml
    config = {"model": {"provider": "custom", "default": "hermes-ios-fixture", "base_url": f"http://127.0.0.1:{args.model_port}/v1"}, "terminal": {"backend": "local", "cwd": str(home)}, "dashboard": {"public_url": "http://hermes-ios.test"}, "compression": {"enabled": False}}
    config["approvals"] = {"mode": "off"}  # Disposable fixture only: deterministic terminal sleep.
    config["stt"] = {"provider": "openai"}
    config["tts"] = {"provider": "openai", "openai": {"base_url": f"http://127.0.0.1:{args.model_port}/v1", "voice": "alloy"}}
    if args.live_fixture:
        from voice_live_fixture import LiveFixture
        Model.live_fixture = LiveFixture()
        config["voice"] = {"voice_chat_mode": "gpt-live", "gpt_live": {"model": "gpt-live-1", "voice": "stone", "api_key": "local-fixture-only", "base_url": f"http://127.0.0.1:{args.model_port}/v1"}}
    if args.push_plugin:
        import shutil
        plugin = Path(__file__).resolve().parent.parent / "server" / "hermes-ios-push"
        shutil.copytree(plugin, home / "plugins" / "hermes-ios-push")
        config["plugins"] = {"enabled": ["hermes-ios-push"]}
    if args.gemini_voix:
        import shutil
        shutil.copytree(Path(__file__).resolve().parent.parent / "server" / "hermes-gemini-voix", home / "plugins" / "gemini-voix")
        config.setdefault("plugins", {}).setdefault("enabled", []).append("gemini-voix")
        config["tts"] = {"provider": "gemini-voix", "gemini": {"model": "gemini-3.8-flash-lite-tts", "voice": "Ma voix québécoise", "base_url": f"http://127.0.0.1:{args.model_port}/v1beta"}}
    (home / "config.yaml").write_text(yaml.safe_dump(config))
    # Hermes 0.21.7 scopes provider secrets to each profile's .env; the process env alone no longer reaches them.
    fixture_env = f"OPENAI_API_KEY=hermes-ios-local-fixture\nOPENAI_BASE_URL=http://127.0.0.1:{args.model_port}/v1\nSTT_OPENAI_BASE_URL=http://127.0.0.1:{args.model_port}/v1\n"
    if args.gemini_voix:
        fixture_env += "GEMINI_API_KEY=hermes-ios-gemini-fixture\n"
    (home / ".env").write_text(fixture_env)
    for name in ["research", "studio"]:
        profile = home / "profiles" / name
        profile.mkdir(parents=True)
        profile_config = {**config, "tts": config["tts"] if args.gemini_voix else {"provider": "openai", "openai": {"base_url": f"http://127.0.0.1:{args.model_port}/v1", "voice": "nova" if name == "research" else "echo"}}}
        (profile / "config.yaml").write_text(yaml.safe_dump(profile_config))
        (profile / ".env").write_text(fixture_env)
        if args.push_plugin or args.gemini_voix:
            (profile / "plugins").mkdir()
        if args.push_plugin:
            (profile / "plugins" / "hermes-ios-push").symlink_to(home / "plugins" / "hermes-ios-push", target_is_directory=True)
        if args.gemini_voix:
            (profile / "plugins" / "gemini-voix").symlink_to(home / "plugins" / "gemini-voix", target_is_directory=True)
        profile_meta = {"name": name, "description": "Profil de test HermesIOS"}
        if name == "research" and args.push_plugin:
            profile_meta["ui_meta"] = {"hermes-bots": {"title": "Chercheur"}}   # display name used by encrypted notifications
        (profile / "profile.yaml").write_text(yaml.safe_dump(profile_meta))
    env = {"PATH": str(Path(sys.executable).parent) + os.pathsep + os.defpath, "LANG": "en_US.UTF-8", "HERMES_HOME": str(home), "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "hermes-ios-test", "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": "hermes-ios-local-fixture", "HERMES_DASHBOARD_BASIC_AUTH_SECRET": secrets.token_urlsafe(32), "STT_OPENAI_BASE_URL": f"http://127.0.0.1:{args.model_port}/v1", "OPENAI_API_KEY": "hermes-ios-local-fixture", "OPENAI_BASE_URL": f"http://127.0.0.1:{args.model_port}/v1"}
    if args.upstream_root:
        assert (args.upstream_root / "hermes_cli" / "main.py").is_file()
        env["PYTHONPATH"] = str(args.upstream_root.resolve())
    model = ThreadingHTTPServer(("127.0.0.1", args.model_port), Model)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    process = subprocess.Popen([sys.executable, "-m", "hermes_cli.main", "serve", "--host", "127.0.0.1", "--port", str(args.port)], env=env, cwd=home)
    def stop(*_):
        process.terminate()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"Isolated Hermes: http://127.0.0.1:{args.port}; fixture login: hermes-ios-test / hermes-ios-local-fixture", flush=True)
    try:
        process.wait()
    finally:
        model.shutdown()
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=10)


if __name__ == "__main__":
    main()
