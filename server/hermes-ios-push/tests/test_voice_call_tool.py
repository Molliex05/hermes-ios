import importlib.util
import json
import pathlib
import unittest

TOOL = pathlib.Path(__file__).resolve().parents[1] / "voice_call_tool.py"
spec = importlib.util.spec_from_file_location("voice_call_tool", TOOL)
voice_call_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice_call_tool)


class VoiceCallToolTests(unittest.TestCase):
    def test_takes_no_parameter_and_only_confirms(self):
        self.assertEqual(voice_call_tool.SCHEMA["name"], "terminer_appel")
        self.assertEqual(voice_call_tool.SCHEMA["parameters"]["properties"], {})
        self.assertTrue(json.loads(voice_call_tool.handle({}, session_id="s"))["ok"])
        self.assertTrue(json.loads(voice_call_tool.handle(None))["ok"])

    def test_the_app_and_the_plugin_agree_on_the_name(self):
        swift = (TOOL.parents[2] / "HermesIOS/Core/VoiceActivity.swift").read_text()
        self.assertIn(f'hangUpTool = "{voice_call_tool.NAME}"', swift)


if __name__ == "__main__":
    unittest.main()
