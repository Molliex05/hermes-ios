"""Companion for the cold-launch XCUITest. Uses only the dedicated QA simulator."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
sim = 'CB425B6F-338C-4AB4-B065-14CC8D99C7E8'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
for _ in range(240):
    log = output / 'ui.log'
    if log.exists() and 'HERMES_NOTIFICATION_READY' in log.read_text(errors='replace'):
        break
    time.sleep(1)
else:
    raise SystemExit('UI test did not reach the notification injection checkpoint')
container = Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,'org.hermesios.HermesIOS','data'],env=env,text=True).strip())
connections = json.loads((container / 'Library/Application Support/HermesIOS/connections.json').read_text())
connection = next(c for c in connections if c['endpoint']['baseURL']=='http://127.0.0.1:19133')
payload = json.loads((output / 'cron-notification.apns').read_text())
payload['hermes']['connection_id'] = connection['id']
payload['Simulator Target Bundle'] = 'org.hermesios.HermesIOS'
file = output / 'simulator-notification.apns';file.write_text(json.dumps(payload))
subprocess.run(['xcrun','simctl','push',sim,'org.hermesios.HermesIOS',str(file)],env=env,check=True)
print('Injected real cron target into the terminated QA app',flush=True)
