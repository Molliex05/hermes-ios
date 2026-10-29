import asyncio, importlib.util, sys, unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("alertes", Path(__file__).resolve().parent.parent / "scripts" / "hermes_alertes.py")
alertes = importlib.util.module_from_spec(spec); sys.modules["alertes"] = alertes; spec.loader.exec_module(alertes)

HOST = {"ok": True, "host": {"hostname": "noriven-prod", "cpu_count": 4, "loadavg": [0.2, 0.19, 0.18],
                              "memory": {"mem_total": "8131768 kB", "mem_available": "6331552 kB"},
                              "disk": {"total_bytes": 123690532864, "used_bytes": 34402484224}, "docker": {"containers_seen": 14, "unhealthy": []}}}
SERVICES = {"ok": True, "services": [{"alias": "glutax-main", "status": "running", "health": "healthy", "restarts": 0},
                                     {"alias": "postgrest-auth", "status": "running", "health": "n/a", "restarts": 1}]}
BACKUPS = {"ok": True, "backups": [{"name": "Postgres", "condition": "unchecked", "stale": True}, {"name": "Fichiers", "condition": "unchecked", "stale": True}]}


def changed(base, **edits):
    import copy
    value = copy.deepcopy(base)
    for path, new in edits.items():
        target = value
        keys = path.split("__")
        for key in keys[:-1]:
            target = target[key]
        target[keys[-1]] = new
    return value


class Evaluate(unittest.TestCase):
    def test_a_healthy_server_says_nothing_even_with_unchecked_backups(self):
        self.assertEqual(alertes.evaluate(HOST, SERVICES, BACKUPS), [])

    def test_each_problem_has_one_stable_line(self):
        host = changed(HOST, host__disk__used_bytes=110 * 10**9, host__memory__mem_available="500000 kB", host__loadavg=[9, 9, 9.5],
                       host__docker__unhealthy=["coolify-proxy"])
        services = {"services": [{"alias": "minori-production", "status": "exited", "health": "n/a", "restarts": 0},
                                 {"alias": "auth-production", "status": "running", "health": "unhealthy", "restarts": 0},
                                 {"alias": "noriven-main", "status": "running", "health": "healthy", "restarts": 5}]}   # restarts alone are no alert
        backups = {"backups": [{"name": "Postgres", "condition": "stale"}, {"name": "Fichiers", "condition": "unchecked"}]}
        lines = alertes.evaluate(host, services, backups)
        self.assertEqual(lines, sorted(lines))
        for expected in ("noriven-prod : disque utilisé à plus de 85 %", "noriven-prod : moins de 10 % de mémoire disponible",
                         "noriven-prod : charge soutenue très élevée", "service en mauvaise santé : coolify-proxy",
                         "service arrêté : minori-production", "service en mauvaise santé : auth-production",
                         "sauvegarde en retard ou en échec : Postgres"):
            self.assertIn(expected, lines)
        self.assertEqual(len(lines), 7, "an unchecked backup and a lifetime restart count are not alerts")

    def test_the_text_does_not_move_with_the_live_values(self):
        a = alertes.evaluate(changed(HOST, host__disk__used_bytes=106 * 10**9), SERVICES, BACKUPS)
        b = alertes.evaluate(changed(HOST, host__disk__used_bytes=118 * 10**9), SERVICES, BACKUPS)
        self.assertEqual(a, b); self.assertEqual(len(a), 1)

    def test_a_blind_answer_is_an_error_but_odd_numbers_are_not(self):
        with self.assertRaises(ValueError):
            alertes.evaluate({"ok": True}, SERVICES, BACKUPS)
        with self.assertRaises(ValueError):
            alertes.evaluate(HOST, {"ok": True}, BACKUPS)
        odd = {"host": {"disk": {"total_bytes": 100, "used_bytes": None}, "memory": {"mem_total": "x"}, "cpu_count": "4", "loadavg": {}, "docker": None}}
        self.assertEqual(alertes.evaluate(odd, {"services": [{}, "x"]}, {"backups": [{}, None]}), [])

    def test_an_alert_clears_only_past_a_margin(self):
        line = "noriven-prod : disque utilisé à plus de 85 %"
        at = lambda used: changed(HOST, host__disk__used_bytes=int(used * HOST["host"]["disk"]["total_bytes"]))
        self.assertEqual(alertes.evaluate(at(0.84), SERVICES, BACKUPS), [], "84 % never raised it")
        self.assertEqual(alertes.evaluate(at(0.86), SERVICES, BACKUPS), [line])
        self.assertEqual(alertes.evaluate(at(0.83), SERVICES, BACKUPS, previous=[line]), [line], "raised: it stays until below 80 %")
        self.assertEqual(alertes.evaluate(at(0.79), SERVICES, BACKUPS, previous=[line]), [])


class Collect(unittest.TestCase):
    def test_a_broken_answer_is_an_error_not_a_calm_server(self):
        async def call(name, args):
            return {"ok": False} if name == "ops_get_backups" else {"ok": True}
        with self.assertRaises(RuntimeError):
            asyncio.run(alertes.collect(call))

    def test_collect_reads_the_three_tools(self):
        async def call(name, args):
            return {"ops_get_host": HOST, "ops_list_services": SERVICES, "ops_get_backups": BACKUPS}[name]
        self.assertEqual(asyncio.run(alertes.collect(call)), [])


if __name__ == "__main__":
    unittest.main()
