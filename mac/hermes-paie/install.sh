#!/bin/zsh
# Installe le service « paie » sur le Mac mini : une copie du code sur le disque interne (le service ne dépend pas du SSD),
# un agent launchd qui écoute le port 8790 et lance le script seulement à chaque appel, et le jeton du service dans le
# trousseau s'il n'existe pas encore. Rejouable : il met à jour la copie et recharge l'agent.
set -euo pipefail

HERE=${0:A:h}
APP="$HOME/Library/Application Support/hermes-paie/app"
PLIST="$HOME/Library/LaunchAgents/com.noriven.hermes-paie.plist"
LABEL="com.noriven.hermes-paie"
PORT=8790

mkdir -p "$APP" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$HERE/paie.py" "$HERE/service.py" "$APP/"

# Le lanceur n'est recompilé que si sa source change : macOS rattache l'Accès complet au disque à ce binaire précis,
# un nouveau binaire devrait être autorisé de nouveau.
if [[ ! -x "$APP/hermes-paie" ]] || ! cmp -s "$HERE/launcher.c" "$APP/launcher.c"; then
  /usr/bin/clang -O2 -Wall -o "$APP/hermes-paie" "$HERE/launcher.c"
  /usr/bin/codesign -s - -f -i com.noriven.hermes-paie "$APP/hermes-paie" 2>/dev/null
  cp "$HERE/launcher.c" "$APP/launcher.c"
  echo "Lanceur compilé : donne-lui l'Accès complet au disque ($APP/hermes-paie)."
fi

if ! /usr/bin/security find-generic-password -s hermes-paie-service >/dev/null 2>&1; then
  # Le jeton n'est jamais affiché : il passe du générateur au trousseau.
  /usr/bin/python3 -I -c 'import secrets, subprocess; subprocess.run(["/usr/bin/security", "add-generic-password", "-s", "hermes-paie-service", "-a", "jarvis", "-l", "Service paie (Jarvis)", "-w", secrets.token_urlsafe(32)], check=True)'
  echo "Jeton du service créé dans le trousseau."
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/hermes-paie</string>
  </array>
  <key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockServiceName</key><string>$PORT</string>
      <key>SockType</key><string>stream</string>
      <key>SockFamily</key><string>IPv4</string>
    </dict>
  </dict>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/hermes-paie.log</string>
</dict>
</plist>
PLIST

/bin/launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$UID" "$PLIST"
echo "Service installé : port $PORT, lancé seulement à chaque appel."
