#!/bin/bash
# Install the configured credentialless runner as a no-login system LaunchDaemon.
set +x
set -euo pipefail
umask 077

SERVICE_LABEL="org.autonomous-engineering-system.forge-platform.build-runner"
PLIST_PATH="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"
BUILD_USER="${FORGE_PLATFORM_EXPECTED_BUILD_USER:-}"
RUNNER_NAME="${FORGE_PLATFORM_RUNNER_NAME:-forge-platform-macmini-build}"

fail() { echo "BUILD_RUNNER_SERVICE=FAIL reason=$1" >&2; exit 1; }
[[ "$(id -u)" == "0" ]] || fail root-required
[[ -n "$BUILD_USER" ]] || fail expected-build-user-required
build_uid="$(id -u "$BUILD_USER" 2>/dev/null)" || fail build-user-missing
[[ "$build_uid" =~ ^[0-9]+$ && "$build_uid" -ge 500 ]] || fail build-user-is-not-local-standard-user
build_home="$(dscacheutil -q user -a name "$BUILD_USER" | awk -F': ' '/^dir: / {print $2; exit}')"
[[ "$build_home" == "/Users/$BUILD_USER" ]] || fail build-user-home-mismatch
if dseditgroup -o checkmember -m "$BUILD_USER" admin 2>/dev/null | grep -Fq 'yes'; then
  fail build-user-must-not-be-admin
fi

auto_login="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
[[ -z "$auto_login" ]] || fail automatic-login-must-be-disabled
[[ ! -e /etc/kcpassword ]] || fail automatic-login-secret-present

RUNNER_ROOT="${FORGE_PLATFORM_RUNNER_ROOT:-$build_home/actions-runner-forge-platform-build}"
[[ "$RUNNER_ROOT" == "$build_home/actions-runner-forge-platform-build" ]] || fail runner-root-mismatch
[[ -f "$RUNNER_ROOT/.runner" && -x "$RUNNER_ROOT/runsvc.sh" ]] || fail configured-runner-unavailable
[[ "$(stat -f '%Su' "$RUNNER_ROOT")" == "$BUILD_USER" ]] || fail runner-root-owner-mismatch
runner_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig")).get("agentName", ""))' "$RUNNER_ROOT/.runner")"
[[ "$runner_name" == "$RUNNER_NAME" ]] || fail runner-name-mismatch
[[ ! -f "$RUNNER_ROOT/.service" ]] || fail per-user-service-must-not-be-installed
if [[ -d "$build_home/Library/LaunchAgents" ]] && find "$build_home/Library/LaunchAgents" -maxdepth 1 -name 'actions.runner.*.plist' -print -quit | grep -q .; then
  fail per-user-launchagent-must-not-be-installed
fi
if sudo -H -u "$BUILD_USER" security find-identity -v -p codesigning 2>/dev/null | grep -Fq 'Developer ID Application:'; then
  fail developer-id-visible-in-build-account
fi

LOG_ROOT="/var/log/$SERVICE_LABEL"
install -d -o "$BUILD_USER" -g staff -m 0700 "$LOG_ROOT"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVICE_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$RUNNER_ROOT/runsvc.sh</string></array>
  <key>UserName</key><string>$BUILD_USER</string>
  <key>WorkingDirectory</key><string>$RUNNER_ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG_ROOT/stdout.log</string>
  <key>StandardErrorPath</key><string>$LOG_ROOT/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict><key>ACTIONS_RUNNER_SVC</key><string>1</string></dict>
</dict>
</plist>
EOF
plutil -lint "$tmp" >/dev/null || fail invalid-launchdaemon-plist
launchctl bootout "system/$SERVICE_LABEL" >/dev/null 2>&1 || true
install -o root -g wheel -m 0644 "$tmp" "$PLIST_PATH"
launchctl bootstrap system "$PLIST_PATH" || fail launchdaemon-bootstrap-failed
launchctl enable "system/$SERVICE_LABEL" || fail launchdaemon-enable-failed
launchctl kickstart -k "system/$SERVICE_LABEL" || fail launchdaemon-kickstart-failed

for _ in {1..20}; do
  if launchctl print "system/$SERVICE_LABEL" 2>/dev/null | grep -Eq 'state = (running|waiting)'; then
    break
  fi
  sleep 1
done
launchctl print "system/$SERVICE_LABEL" 2>/dev/null | grep -Eq 'state = (running|waiting)' || fail launchdaemon-not-active
for _ in {1..20}; do
  if pgrep -u "$build_uid" -f "$RUNNER_ROOT/bin/Runner.Listener" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
pgrep -u "$build_uid" -f "$RUNNER_ROOT/bin/Runner.Listener" >/dev/null 2>&1 || fail runner-listener-not-owned-by-build-user

echo "BUILD_RUNNER_SERVICE=PASS label=$SERVICE_LABEL user=$BUILD_USER uid=$build_uid runner=$RUNNER_NAME root=$RUNNER_ROOT automatic_login=disabled"
echo "BUILD_RUNNER_REBOOT_PERSISTENCE=NOT_VERIFIED action=record-reboot-verify"
