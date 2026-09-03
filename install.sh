#!/usr/bin/env bash
# pastethrough - paste clipboard images into Claude Code on a remote host.
#
#   ./install.sh <host>              install locally and on <host>
#   ./install.sh --check <host>      verify the whole path end to end
#   ./install.sh --uninstall <host>  remove everything for <host>
#
# <host> is any name your ssh config resolves.
set -euo pipefail

PORT="${PASTETHROUGH_PORT:-5556}"
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
SERVER_LABEL="dev.local.pastethrough.server"
DOMAIN="gui/$(id -u)"

die() { echo "error: $*" >&2; exit 1; }
tunnel_label() { echo "dev.local.pastethrough.tunnel.$1"; }

require_macos() {
  [ "$(uname -s)" = "Darwin" ] && return 0
  die "the client side is macOS only. It uses osascript and launchd."
}

# ---------------------------------------------------------------- install

install_local() {
  require_macos
  local socat
  socat=$(command -v socat) || die "socat not found. Run: brew install socat"

  mkdir -p "$BIN" "$AGENTS" "$LOGS"
  install -m 755 "$HERE/bin/clip-png" "$BIN/clip-png"

  cat > "$AGENTS/$SERVER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$socat</string>
    <string>TCP-LISTEN:$PORT,bind=127.0.0.1,reuseaddr,fork</string>
    <string>EXEC:$BIN/clip-png</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$LOGS/pastethrough-server.log</string>
</dict>
</plist>
PLIST
  reload "$SERVER_LABEL"
  echo "  local: clipboard server on 127.0.0.1:$PORT"
}

install_tunnel() {
  local host=$1 label
  label=$(tunnel_label "$host")
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-R</string><string>$PORT:localhost:$PORT</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>$host</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardErrorPath</key><string>$LOGS/pastethrough-tunnel-$host.log</string>
</dict>
</plist>
PLIST
  reload "$label"
  echo "  tunnel: $host:$PORT -> this Mac, always on"
}

install_remote() {
  local host=$1
  ssh -o BatchMode=yes "$host" 'mkdir -p ~/.local/bin' \
    || die "cannot ssh to $host without a password. Set up key auth first."
  scp -q "$HERE/bin/xclip-shim" "$host:.local/bin/.xclip.new"
  ssh -o BatchMode=yes "$host" \
    'mv ~/.local/bin/.xclip.new ~/.local/bin/xclip && chmod +x ~/.local/bin/xclip'
  echo "  remote: $host:~/.local/bin/xclip"

  local resolved
  resolved=$(ssh -o BatchMode=yes "$host" 'bash -lc "command -v xclip"' 2>/dev/null || true)
  case "$resolved" in
    */.local/bin/xclip) ;;
    *) echo "  WARNING: a login shell on $host resolves xclip to '${resolved:-nothing}'."
       echo "           Put ~/.local/bin ahead of /usr/bin in the PATH there." ;;
  esac
}

reload() {
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$AGENTS/$1.plist"
}

# ---------------------------------------------------------------- check

check() {
  local host=$1 png tmp rc=0
  png=$(mktemp -t ptcheck).png
  # A 1x1 PNG, so the check never depends on what you happen to have copied.
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' \
    | base64 -d > "$png"
  echo "note: this replaces your clipboard with a 1x1 test image."
  osascript -e "set the clipboard to (read (POSIX file \"$png\") as «class PNGf»)"
  rm -f "$png"

  step "local clipboard reads as PNG" \
    "[ \"\$($BIN/clip-png | wc -c)\" -gt 0 ]" || rc=1
  step "clipboard server answers on 127.0.0.1:$PORT" \
    "[ -n \"\$(nc -w 3 127.0.0.1 $PORT | head -c 4)\" ]" || rc=1
  step "tunnel carries PNG bytes to $host" \
    "[ \"\$(ssh -o BatchMode=yes $host 'exec 3<>/dev/tcp/127.0.0.1/$PORT && head -c 4 <&3 | xxd -p')\" = 89504e47 ]" || rc=1
  step "shim answers TARGETS on $host" \
    "[ \"\$(ssh -o BatchMode=yes $host 'bash -lc \"xclip -selection clipboard -t TARGETS -o\"' 2>/dev/null)\" = image/png ]" || rc=1
  # Compare inside a substitution. A bare pipeline would trip pipefail, because
  # head closes the pipe and the writer upstream dies with SIGPIPE.
  step "shim delivers the image on $host" \
    "[ \"\$(ssh -o BatchMode=yes $host 'bash -lc \"xclip -selection clipboard -t image/png -o\"' 2>/dev/null | head -c 4 | xxd -p)\" = 89504e47 ]" || rc=1

  [ $rc -eq 0 ] && echo "all checks passed. Press Ctrl+V in Claude Code on $host." \
                || echo "see $LOGS/pastethrough-*.log"
  return $rc
}

step() {
  local name=$1 cmd=$2
  if eval "$cmd" >/dev/null 2>&1; then printf '  ok    %s\n' "$name"
  else printf '  FAIL  %s\n' "$name"; return 1; fi
}

# ---------------------------------------------------------------- uninstall

uninstall() {
  local host=${1:-} label
  launchctl bootout "$DOMAIN/$SERVER_LABEL" 2>/dev/null || true
  rm -f "$AGENTS/$SERVER_LABEL.plist" "$BIN/clip-png"
  echo "  removed the local clipboard server"
  if [ -n "$host" ]; then
    label=$(tunnel_label "$host")
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$AGENTS/$label.plist"
    ssh -o BatchMode=yes "$host" 'rm -f ~/.local/bin/xclip' 2>/dev/null || true
    echo "  removed the tunnel and the shim on $host"
  fi
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  --check)     [ $# -eq 2 ] || die "usage: $0 --check <host>";     check "$2" ;;
  --uninstall) [ $# -ge 1 ] || true;                               uninstall "${2:-}" ;;
  ""|-h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    host=$1
    echo "installing pastethrough for $host"
    install_local
    install_tunnel "$host"
    install_remote "$host"
    sleep 2
    echo "verifying"
    check "$host"
    ;;
esac
