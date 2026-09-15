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
    def log_message(self, *args):
        pass

    def do_GET(self):
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
        if self.path == "/v1/audio/speech":
            import io, wave
            output = io.BytesIO()
            with wave.open(output, "wb") as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                wav.writeframes(b"\x00\x00" * 72000)
            self.send_response(200); self.send_header("Content-Type", "audio/wav"); self.end_headers()
            self.wfile.write(output.getvalue())
            print("Fixture TTS voice: " + str(body.get("voice")), flush=True)
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
    args = parser.parse_args()
    home = args.home.resolve()
    if home.exists() and any(home.iterdir()):
        raise SystemExit("Use a new, empty --home directory; never point at your own Hermes home.")
    home.mkdir(parents=True, exist_ok=True)
    import yaml
    config = {"model": {"provider": "custom", "default": "hermes-ios-fixture", "base_url": f"http://127.0.0.1:{args.model_port}/v1"}, "terminal": {"backend": "local", "cwd": str(home)}, "dashboard": {"public_url": "http://hermes-ios.test"}, "compression": {"enabled": False}}
    config["stt"] = {"provider": "openai"}
    config["tts"] = {"provider": "openai", "openai": {"base_url": f"http://127.0.0.1:{args.model_port}/v1", "voice": "alloy"}}
    (home / "config.yaml").write_text(yaml.safe_dump(config))
    for name in ["research", "studio"]:
        profile = home / "profiles" / name
        profile.mkdir(parents=True)
        profile_config = {**config, "tts": {"provider": "openai", "openai": {"base_url": f"http://127.0.0.1:{args.model_port}/v1", "voice": "nova" if name == "research" else "echo"}}}
        (profile / "config.yaml").write_text(yaml.safe_dump(profile_config))
        (profile / "profile.yaml").write_text(yaml.safe_dump({"name": name, "description": "Profil de test HermesIOS"}))
    env = {"PATH": str(Path(sys.executable).parent) + os.pathsep + os.defpath, "LANG": "en_US.UTF-8", "HERMES_HOME": str(home), "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "hermes-ios-test", "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": "hermes-ios-local-fixture", "HERMES_DASHBOARD_BASIC_AUTH_SECRET": secrets.token_urlsafe(32), "STT_OPENAI_BASE_URL": f"http://127.0.0.1:{args.model_port}/v1", "OPENAI_API_KEY": "hermes-ios-local-fixture", "OPENAI_BASE_URL": f"http://127.0.0.1:{args.model_port}/v1"}
    model = ThreadingHTTPServer(("127.0.0.1", args.model_port), Model)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    process = subprocess.Popen([str(Path(sys.executable).with_name("hermes")), "serve", "--host", "127.0.0.1", "--port", str(args.port)], env=env, cwd=home)
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
