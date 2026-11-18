"""Mirror kubectl/k9s port-forwards from a running box onto localhost on the Mac.

    port-forward.py <container>

Started in the background by the launcher next to `docker run`. The box publishes no ports, so a
`kubectl port-forward` (or k9s port-forward) inside it only listens on the box's own localhost.
This watches which ports those processes listen on (one long-running `docker exec` with a small
node script; node is always in the image) and opens the same port on 127.0.0.1 on the Mac. Each
connection is relayed through its own `docker exec` into the box, so nothing is published and
nothing in the box listens beyond localhost. A port already taken on the Mac is skipped and
retried. The current state is written to /tmp/claude-box-ports in the box, so Claude can tell
you the URL. Exits when the box stops. Standard library only.
"""

import asyncio
import json
import signal
import sys
import time

# Processes whose listening ports are forwarded (as in /proc/<pid>/comm).
FORWARD = ["kubectl", "k9s"]
STATUS_FILE = "/tmp/claude-box-ports"
START_TIMEOUT = 300  # seconds to wait for the box to come up

# Inside the box: print {port: address-to-dial} for the ports FORWARD processes listen on,
# once at start and again whenever it changes.
WATCH = r"""
const fs = require('fs');
const names = new Set(process.argv.slice(1));
function v4(hex) {
  const n = parseInt(hex, 16);
  const ip = [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24].join('.');
  return ip === '0.0.0.0' ? '127.0.0.1' : ip;
}
function scan() {
  const inodes = new Set();
  for (const pid of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(pid)) continue;
    try {
      if (!names.has(fs.readFileSync(`/proc/${pid}/comm`, 'utf8').trim())) continue;
      for (const fd of fs.readdirSync(`/proc/${pid}/fd`)) {
        try {
          const m = /^socket:\[(\d+)\]$/.exec(fs.readlinkSync(`/proc/${pid}/fd/${fd}`));
          if (m) inodes.add(m[1]);
        } catch (e) {}
      }
    } catch (e) {}
  }
  const ports = {};
  for (const [file, six] of [['/proc/net/tcp6', true], ['/proc/net/tcp', false]]) {
    let lines = [];
    try { lines = fs.readFileSync(file, 'utf8').split('\n').slice(1); } catch (e) {}
    for (const line of lines) {
      const f = line.trim().split(/\s+/);
      if (f.length < 10 || f[3] !== '0A' || !inodes.has(f[9])) continue;  // 0A = LISTEN
      const [addr, port] = f[1].split(':');
      ports[parseInt(port, 16)] = six ? '::1' : v4(addr);  // IPv4 wins when both exist
    }
  }
  return ports;
}
let last = null;
function tick() {
  const now = JSON.stringify(scan());
  if (now !== last) { process.stdout.write(now + '\n'); last = now; }
}
tick();
setInterval(tick, 1000);
"""

# Inside the box: one connection, stdin/stdout <-> address:port.
RELAY = r"""
const s = require('net').connect(+process.argv[2], process.argv[1]);
s.on('error', () => process.exit(1));
process.stdin.pipe(s);
s.pipe(process.stdout);
"""


class Forwarder:
    def __init__(self, container: str):
        self.container = container
        self.targets: dict[int, str] = {}  # box port -> address to dial inside the box
        self.servers: dict[int, list[asyncio.AbstractServer]] = {}
        self.children: set[asyncio.subprocess.Process] = set()
        self.status = ""

    async def docker(self, *args, **kw) -> asyncio.subprocess.Process:
        proc = await asyncio.create_subprocess_exec("docker", *args, **kw)
        self.children.add(proc)
        return proc

    async def running(self) -> bool:
        proc = await self.docker("inspect", "-f", "{{.State.Running}}", self.container,
                                 stdout=asyncio.subprocess.PIPE,
                                 stderr=asyncio.subprocess.DEVNULL)
        out, _ = await proc.communicate()
        self.children.discard(proc)
        return out.strip() == b"true"

    async def run(self) -> None:
        asyncio.create_task(self.retry_loop())
        started, seen = time.monotonic(), False
        while True:
            proc = await self.docker("exec", self.container, "node", "-e", WATCH, *FORWARD,
                                     stdin=asyncio.subprocess.DEVNULL,
                                     stdout=asyncio.subprocess.PIPE,
                                     stderr=asyncio.subprocess.DEVNULL)
            assert proc.stdout is not None
            async for line in proc.stdout:
                seen = True
                try:
                    ports = {int(p): a for p, a in json.loads(line).items()}
                except ValueError:
                    continue
                await self.apply(ports)
            await proc.wait()
            self.children.discard(proc)
            if not await self.running() and (seen or time.monotonic() - started > START_TIMEOUT):
                return
            await asyncio.sleep(1)

    async def apply(self, ports: dict[int, str]) -> None:
        for port in list(self.targets):
            if port not in ports:
                for server in self.servers.pop(port, []):
                    server.close()
        self.targets = ports
        await self.open_missing()

    async def open_missing(self) -> None:
        for port in self.targets:
            if port not in self.servers:
                servers = await self.listen(port)
                if servers:
                    self.servers[port] = servers
        await self.write_status()

    async def listen(self, port: int) -> list[asyncio.AbstractServer]:
        """Listen on localhost on the Mac (IPv4, and IPv6 when it is free too)."""
        handler = lambda r, w: self.relay(port, r, w)  # noqa: E731
        try:
            servers = [await asyncio.start_server(handler, "127.0.0.1", port)]
        except OSError:
            return []
        try:
            servers.append(await asyncio.start_server(handler, "::1", port))
        except OSError:
            pass
        return servers

    async def retry_loop(self) -> None:
        """Ports that were busy on the Mac get forwarded as soon as they are free."""
        while True:
            await asyncio.sleep(5)
            if any(p not in self.servers for p in self.targets):
                await self.open_missing()

    async def write_status(self) -> None:
        lines = ["# kubectl/k9s port-forwards in this box, mirrored to the Mac by claude-box"]
        for port in sorted(self.targets):
            if port in self.servers:
                lines.append(f"{port}: forwarded, open http://localhost:{port} on the Mac")
            else:
                lines.append(f"{port}: not forwarded, port {port} is already in use on the Mac")
        status = "\n".join(lines) + "\n"
        if status == self.status:
            return
        self.status = status
        proc = await self.docker("exec", "-i", self.container, "sh", "-c",
                                 f"cat > {STATUS_FILE}",
                                 stdin=asyncio.subprocess.PIPE,
                                 stdout=asyncio.subprocess.DEVNULL,
                                 stderr=asyncio.subprocess.DEVNULL)
        await proc.communicate(status.encode())
        self.children.discard(proc)

    async def relay(self, port: int, reader: asyncio.StreamReader,
                    writer: asyncio.StreamWriter) -> None:
        address = self.targets.get(port)
        if address is None:
            writer.close()
            return
        proc = await self.docker("exec", "-i", self.container, "node", "-e", RELAY,
                                 address, str(port),
                                 stdin=asyncio.subprocess.PIPE,
                                 stdout=asyncio.subprocess.PIPE,
                                 stderr=asyncio.subprocess.DEVNULL)
        assert proc.stdin is not None and proc.stdout is not None

        async def upstream() -> None:
            try:
                while data := await reader.read(65536):
                    proc.stdin.write(data)
                    await proc.stdin.drain()
            except (ConnectionError, OSError):
                pass
            finally:
                proc.stdin.close()  # half-close: the box side sees EOF

        up = asyncio.create_task(upstream())
        try:
            while data := await proc.stdout.read(65536):
                writer.write(data)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()
            up.cancel()
            try:
                await asyncio.wait_for(proc.wait(), 5)
            except asyncio.TimeoutError:
                proc.kill()
            self.children.discard(proc)

    def stop(self) -> None:
        for proc in list(self.children):
            if proc.returncode is None:
                proc.kill()


async def main(container: str) -> None:
    fwd = Forwarder(container)
    loop = asyncio.get_running_loop()
    done = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(sig, done.set)
    runner = asyncio.create_task(fwd.run())
    stopper = asyncio.create_task(done.wait())
    await asyncio.wait({runner, stopper}, return_when=asyncio.FIRST_COMPLETED)
    fwd.stop()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: port-forward.py <container>")
    asyncio.run(main(sys.argv[1]))
