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
python3 - "$fixture/control" <<'PY'
import os
import select
import struct
import subprocess
import sys
import time

process = subprocess.Popen([
    '/usr/bin/ssh', '-F', '/dev/null', '-S', sys.argv[1],
    '-o', 'BatchMode=yes', '-o', 'ProxyCommand=/usr/bin/false',
    '-T', '-s', '--', '127.0.0.1', 'sftp',
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)

try:
    # Keep stdin open until VERSION is received. Sending EOF immediately after
    # INIT can make sftp-server exit before it flushes its queued response.
    process.stdin.write(struct.pack('>IBI', 5, 1, 3))
    process.stdin.flush()
    deadline = time.monotonic() + 15

    def read_exact(count):
        data = bytearray()
        while len(data) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise RuntimeError(f'SFTP handshake timed out after {len(data)}/{count} bytes')
            chunk = os.read(process.stdout.fileno(), count - len(data))
            if not chunk:
                raise RuntimeError(f'SFTP closed before completing its response ({len(data)}/{count} bytes)')
            data.extend(chunk)
        return data

    length, = struct.unpack('>I', read_exact(4))
    if not 5 <= length <= 1024 * 1024:
        raise RuntimeError(f'Invalid SFTP response length: {length}')
    packet = read_exact(length)
    kind, version = struct.unpack('>BI', packet[:5])
    if kind != 2 or version != 3:
        raise RuntimeError(f'Expected SFTP VERSION 3, got type={kind}, version={version}')
    process.stdin.close()
    result = process.wait(timeout=10)
    if result != 0:
        raise RuntimeError(f'SSH subsystem exited with status {result}')
    print(f'SFTP v3 handshake over the shared SSH connection passed ({length} bytes)')
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    process.stdin.close()
    process.stdout.close()
PY
/usr/bin/ssh -F /dev/null -S "$fixture/control" -O exit 127.0.0.1
# A disconnected Files channel must fail instead of opening a fresh connection.
if /usr/bin/ssh -F /dev/null -S "$fixture/control" -o BatchMode=yes \
    -o ProxyCommand=/usr/bin/false -T -s -- 127.0.0.1 sftp < /dev/null; then
  echo 'Unexpected independent SSH connection' >&2
  exit 1
fi
