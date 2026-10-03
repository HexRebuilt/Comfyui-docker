#!/usr/bin/env python3
"""Expose the stdio-only ComfyUI MCP server over HTTP.

comfy-mcp is stdio-only by design: `mcp.run(transport="stdio")` is hardcoded
upstream and there is no HTTP transport to switch on. This bridge launches
`comfy-mcp` as a subprocess and re-publishes it as a Streamable HTTP MCP
endpoint, so a client on another machine can reach it.

    python3 mcp-http-bridge.py

Environment:
    MCP_HTTP_HOST        bind address   (default 127.0.0.1)
    MCP_HTTP_PORT        bind port      (default 8081)
    MCP_HTTP_PATH        endpoint path  (default /mcp)
    MCP_PUBLIC_BIND      the address the PORT is published on from the host
                          (compose sets this; defaults to MCP_HTTP_HOST)
    MCP_AUTH_TOKEN       bearer token   (optional on loopback, REQUIRED off it)
    MCP_ALLOW_ANONYMOUS  accepted for compatibility; no longer needed

Security
--------
This endpoint drives a GPU, writes files, and can call hosted partner models
that spend real money, so a token is REQUIRED whenever the bind address is not
loopback -- that case is refused outright rather than quietly allowed.

On loopback the endpoint is reachable only from this machine, so it starts
without a token. That is not a weakening of the network guarantee: the
loopback-only ceiling on anonymous access is unchanged.
"""

from __future__ import annotations

import ipaddress
import os
import sys

LOOPBACK = {"127.0.0.1", "::1", "localhost"}
MIN_TOKEN_LENGTH = 16


def fail(message: str):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def is_loopback(host: str) -> bool:
    if host in LOOPBACK:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        # A hostname: assume it is NOT loopback. Erring towards "public" means
        # an anonymous bind fails closed rather than open.
        return False


def build_verifier(token: str):
    """Bearer-token verifier for the Streamable HTTP transport.

    Uses fastmcp's own TokenVerifier interface rather than hand-rolling ASGI
    middleware, so the SDK rejects unauthenticated requests before a tool is
    ever reached.
    """
    from fastmcp.server.auth import AccessToken, TokenVerifier

    class StaticTokenVerifier(TokenVerifier):
        # Must be async: the SDK's bearer middleware does
        # `await self.token_verifier.verify_token(token)`. A sync method here
        # raises "object NoneType can't be used in 'await' expression" and
        # rejects every request, including the correct token.
        async def verify_token(self, token: str) -> AccessToken | None:
            if not token or not _constant_time_equals(token, EXPECTED):
                return None
            return AccessToken(
                token=token,
                client_id="comfy-mcp-client",
                scopes=[],
            )

    EXPECTED = token  # noqa: N816 - closed over by verify_token

    return StaticTokenVerifier()


def _constant_time_equals(a: str, b: str) -> bool:
    import hmac

    return hmac.compare_digest(a.encode(), b.encode())


def main() -> None:
    host = os.environ.get("MCP_HTTP_HOST", "127.0.0.1")
    port = int(os.environ.get("MCP_HTTP_PORT", "8081"))
    path = os.environ.get("MCP_HTTP_PATH", "/mcp")
    token = os.environ.get("MCP_AUTH_TOKEN", "").strip()
    allow_anonymous = os.environ.get("MCP_ALLOW_ANONYMOUS") == "1"

    # Exposure is decided by where the PORT is published from the host, not by
    # what this process binds. Inside a container MCP_HTTP_HOST must be 0.0.0.0
    # for the published port to reach us at all, so treating 0.0.0.0 as
    # "exposed" would make every containerised deployment require a token --
    # including one published on 127.0.0.1, which nothing else can reach.
    #
    # compose sets MCP_PUBLIC_BIND to the host-side bind for exactly this
    # reason. Standalone runs fall back to MCP_HTTP_HOST.
    public_bind = os.environ.get("MCP_PUBLIC_BIND") or host

    # A token is required for anything reachable off this machine. Loopback is
    # the one case where there is no network exposure to protect, so it is
    # allowed through unauthenticated.
    if not token and not is_loopback(public_bind):
        fail(
            f"MCP_PUBLIC_BIND={public_bind} is not a loopback address, so this "
            "endpoint would be reachable beyond this machine. It drives a GPU "
            "and can spend credits, so MCP_AUTH_TOKEN is required. Generate one "
            "with 'openssl rand -hex 24' and put it in .env. To keep it local "
            "instead, set MCP_BIND_ADDR=127.0.0.1 in .env and reach it over SSH "
            "or a tailscale tunnel."
        )

    if allow_anonymous and not token:
        # Accepted, but no longer necessary: loopback already permits this.
        print(
            "Note: MCP_ALLOW_ANONYMOUS is no longer needed; a loopback bind "
            "starts without a token by default.",
            file=sys.stderr,
        )

    if token and len(token) < MIN_TOKEN_LENGTH:
        fail(
            f"MCP_AUTH_TOKEN is only {len(token)} characters; use at least "
            f"{MIN_TOKEN_LENGTH}, e.g. openssl rand -hex 24"
        )

    mode = "bearer token" if token else "ANONYMOUS (loopback only)"
    print(f"ComfyUI MCP bridge on http://{host}:{port}{path} [auth: {mode}]", file=sys.stderr)

    # Imported after validation so a misconfiguration fails fast, before
    # anything heavy is loaded or a subprocess is spawned.
    from fastmcp.client.transports import StdioTransport
    from fastmcp.server import create_proxy

    proxy = create_proxy(StdioTransport(command="comfy-mcp", args=[], env=dict(os.environ)))

    if token:
        proxy.auth = build_verifier(token)  # type: ignore[attr-defined]

    proxy.run(transport="http", host=host, port=port, path=path)


if __name__ == "__main__":
    main()
