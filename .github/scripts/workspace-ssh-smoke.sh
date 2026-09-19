#!/usr/bin/env bash
# CI only: isolated loopback sshd, temporary credentials, no Remote Login changes.
set -euo pipefail
fixture=$(mktemp -d /tmp/ghostty-ssh-ci.XXXXXX)
sshd_pid=""
cleanup() {
  /usr/bin/ssh -F /dev/null -S "$fixture/control" -O exit localhost >/dev/null 2>&1 || true
  if [[ -n "$sshd_pid" ]]; then sudo kill "$sshd_pid" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture/host"
ssh-keygen -q -t ed25519 -N '' -f "$fixture/client"
cp "$fixture/client.pub" "$fixture/authorized_keys"
# A dedicated CI job uses a single isolated server.
port=22229
cat > "$fixture/sshd_config" <<CONFIG
Port $port
ListenAddress 127.0.0.1
HostKey $fixture/host
PidFile $fixture/sshd.pid
AuthorizedKeysFile $fixture/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
Subsystem sftp /usr/libexec/sftp-server
CONFIG
sudo /usr/sbin/sshd -f "$fixture/sshd_config" -E "$fixture/sshd.log"
sshd_pid=$(cat "$fixture/sshd.pid")
awk -v address="[127.0.0.1]:$port" '{print address, $1, $2}' "$fixture/host.pub" > "$fixture/known_hosts"
/usr/bin/ssh -F /dev/null -M -S "$fixture/control" -fN \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$fixture/known_hosts" -i "$fixture/client" \
  -p "$port" "$(id -un)@127.0.0.1"
/usr/bin/ssh -F /dev/null -S "$fixture/control" -O check 127.0.0.1
# Once authenticated, Files' restricted slave needs neither credentials nor config.
printf '\000\000\000\005\001\000\000\000\003' | \
  /usr/bin/ssh -F /dev/null -S "$fixture/control" -o BatchMode=yes \
  -o ProxyCommand=/usr/bin/false -T -s -- 127.0.0.1 sftp > "$fixture/version"
python3 - "$fixture/version" <<'PY'
import pathlib
import struct
import sys
packet = pathlib.Path(sys.argv[1]).read_bytes()
assert len(packet) >= 9
length, kind, version = struct.unpack('>IBI', packet[:9])
assert kind == 2 and version == 3 and len(packet) == length + 4
PY
/usr/bin/ssh -F /dev/null -S "$fixture/control" -O exit 127.0.0.1
# A disconnected Files channel must fail instead of opening a fresh connection.
if /usr/bin/ssh -F /dev/null -S "$fixture/control" -o BatchMode=yes \
    -o ProxyCommand=/usr/bin/false -T -s -- 127.0.0.1 sftp < /dev/null; then
  echo 'Unexpected independent SSH connection' >&2
  exit 1
fi
