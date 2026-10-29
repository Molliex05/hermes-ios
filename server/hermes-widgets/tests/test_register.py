import importlib.util, sys, types, unittest
from pathlib import Path

here = Path(__file__).resolve().parent.parent


class Ctx:
    def __init__(self): self.tools = []
    def register_tool(self, **kwargs): self.tools.append(kwargs["name"])


def load(profile):
    constants = types.ModuleType("hermes_constants")
    constants.get_hermes_home = lambda: Path("/x")
    constants.profile_name_for_home = lambda home: profile
    sys.modules["hermes_constants"] = constants
    spec = importlib.util.spec_from_file_location(f"widgets_init_{profile or 'none'}", here / "__init__.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    ctx = Ctx(); module.register(ctx)
    return ctx.tools


class Register(unittest.TestCase):
    def test_the_figures_belong_to_hermes_and_the_board_to_everyone(self):
        self.assertEqual(sorted(load("noriven")), ["noriven_chiffres", "widget_publier"])
        self.assertEqual(load("personnel"), ["widget_publier"], "Jarvis does not get Noriven's figures")
        self.assertEqual(sorted(load("")), ["noriven_chiffres", "widget_publier"], "unknown profile: as before")

    def test_the_board_tool_refuses_the_email_assistant_platform(self):
        constants = types.ModuleType("hermes_constants"); constants.get_hermes_home = lambda: Path("/tmp/none")
        sys.modules["hermes_constants"] = constants
        gateway = types.ModuleType("gateway"); session = types.ModuleType("gateway.session_context")
        session.get_session_env = lambda name, default="": "api_server"
        sys.modules["gateway"], sys.modules["gateway.session_context"] = gateway, session
        try:
            spec = importlib.util.spec_from_file_location("widgets_init_block", here / "__init__.py")
            module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
            self.assertIn("indisponible", module.handle_board({"lignes": [{"texte": "x"}]}))
        finally:
            sys.modules.pop("gateway", None); sys.modules.pop("gateway.session_context", None)


if __name__ == "__main__":
    unittest.main()
