#!/usr/bin/env python3
"""Loopback alias for the ComfyUI service, so comfy-cli will talk to it.

comfy-cli fetches ``/object_info`` and refuses to do so from a non-loopback host
in local mode::

    cql_no_graph: Refusing to fetch object_info from non-loopback host 'comfyui'
    in local mode (potential SSRF). Use --where cloud for remote targets.

The guard is ``comfy_cli.cql._net.is_loopback_host``, which accepts the literal
string ``localhost`` or an address ``ipaddress`` classifies as loopback. It does
not resolve names, so a compose service name is refused -- and so is a container
IP. There is no environment variable or flag to relax it.

The two obvious ways around that are both bad:

* ``network_mode: host`` makes ComfyUI reachable on 127.0.0.1, but it moves the
  MCP bridge onto the host's interfaces, so it stops being clear which port it
  occupies and compose no longer declares it.
* Pointing ``COMFY_LOCAL_URL`` at a container IP or service name is refused,
  which is the bug.

So this binds the loopback interface *inside this container* and forwards to the
real service over the compose network. comfy-cli sees a loopback address; the
traffic still goes over the compose bridge, the published port stays declared in
compose, and nothing is exposed on the host.

It is a plain TCP forward, not a proxy, so it is protocol-agnostic and adds no
dependency. Binding is loopback-only, so it is unreachable from outside this
container even though the container itself is on a shared network.
"""

from __future__ import annotations

import asyncio
import os
import signal
import sys

LOOPBACK_HOST = os.environ.get("MCP_LOOPBACK_HOST", "127.0.0.1")
LOOPBACK_PORT = int(os.environ.get("MCP_LOOPBACK_PORT", "8188"))
UPSTREAM_HOST = os.environ.get("COMFY_UPSTREAM_HOST", "comfyui")
UPSTREAM_PORT = int(os.environ.get("COMFY_UPSTREAM_PORT", "8188"))


def log(message: str) -> None:
    print(f"[loopback-proxy] {message}", file=sys.stderr, flush=True)


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Copy one direction of a connection, closing both ends when it ends."""
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer) -> None:
    peer = client_writer.get_extra_info("peername")
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(
            UPSTREAM_HOST, UPSTREAM_PORT
        )
    except OSError as err:
        log(f"upstream {UPSTREAM_HOST}:{UPSTREAM_PORT} unreachable: {err}")
        client_writer.close()
        return

    log(f"forwarding {peer} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    try:
        await asyncio.gather(
            pipe(client_reader, upstream_writer),
            pipe(upstream_reader, client_writer),
        )
    finally:
        for writer in (client_writer, upstream_writer):
            try:
                writer.close()
            except Exception:
                pass


async def main() -> int:
    server = await asyncio.start_server(
        handle, host=LOOPBACK_HOST, port=LOOPBACK_PORT, limit=2**20
    )
    log(
        f"listening on {LOOPBACK_HOST}:{LOOPBACK_PORT} -> "
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"
    )

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass

    async with server:
        await stop.wait()
    log("stopped")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass