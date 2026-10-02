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
    MCP_AUTH_TOKEN       bearer token   (required unless MCP_ALLOW_ANONYMOUS=1)
    MCP_ALLOW_ANONYMOUS  set 1 to skip auth (refused on a non-loopback bind)

Security
--------
This endpoint drives a GPU, writes files, and can call hosted partner models
that spend real money. comfy-mcp itself is unauthenticated, so authentication
is enforced here and is mandatory by default: binding anywhere other than
loopback without a token is refused rather than quietly allowed.
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

    if not token and not allow_anonymous:
        fail(
            "MCP_AUTH_TOKEN is not set. This endpoint drives a GPU and can spend "
            "credits, so it will not start unauthenticated. Set MCP_AUTH_TOKEN "
            "(generate one with: openssl rand -hex 24), or MCP_ALLOW_ANONYMOUS=1 "
            "if it is genuinely reachable only over loopback."
        )

    if not token and not is_loopback(host):
        fail(
            f"MCP_ALLOW_ANONYMOUS=1 but MCP_HTTP_HOST={host} is not a loopback "
            "address. Refusing to expose an unauthenticated MCP server beyond "
            "this machine. Bind 127.0.0.1 and use an SSH or tailscale tunnel, "
            "or set MCP_AUTH_TOKEN."
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
