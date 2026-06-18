"""OpenHost auth-proxy sidecar for Navidrome.

Sits between the OpenHost router and Navidrome (127.0.0.1:4533) and
auto-logs the OpenHost zone owner in via Navidrome's reverse-proxy auth.

When the router stamps ``X-OpenHost-Is-Owner: true`` (i.e. the visitor is
the authenticated zone owner), this proxy forwards the request to
Navidrome with ``Remote-User: <owner>`` so Navidrome's reverse-proxy auth
(ND_EXTAUTH_* / the deprecated ND_REVERSEPROXY* aliases) signs them in
under their real OpenHost username.  Everyone else is forwarded with no
``Remote-User`` and falls through to Navidrome's normal login, so Subsonic
clients and public share links keep working.

Why a small proxy instead of Caddy: Navidrome resolves the ext-auth
"client" from the X-Forwarded-For chain and only honours ``Remote-User``
when that client is in its trusted sources.  We need precise control of
X-Forwarded-For (pin it to loopback, the only address we trust); doing
that reliably in Caddy proved fragile, whereas here we set every forwarded
header explicitly.  Responses are streamed so audio playback / range
requests are unaffected.

Security model:
  * ``X-OpenHost-Is-Owner`` is trusted because the OpenHost router strips
    any client-supplied ``X-OpenHost-*`` and only re-adds it after
    verifying the session.  We still strip inbound ``Remote-User`` and
    ``X-OpenHost-*`` defensively so a misconfigured router or direct
    container access can't inject auth.
  * Only the owner branch ever sets ``Remote-User``; Navidrome trusts it
    only from 127.0.0.1, which is exactly what this proxy presents.
"""

from __future__ import annotations

import http.client
import logging
import os
import re
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("AUTH_PROXY_LISTEN_PORT", "3000"))
UPSTREAM_HOST = os.environ.get("AUTH_PROXY_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("AUTH_PROXY_UPSTREAM_PORT", "4533"))

OWNER_HEADER_NAME = "X-OpenHost-Is-Owner"
AUTH_HEADER_NAME = "Remote-User"

FALLBACK_OWNER_USERNAME = "admin"
# Navidrome usernames are fairly permissive; keep to a safe charset and a
# sane length, falling back when the OpenHost value is unusable.
_VALID_USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")

HOP_BY_HOP = frozenset(
    h.lower()
    for h in (
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "host",
    )
)
# Never forward these inbound: the auth header (defence in depth), the owner
# marker, and the forwarded-for chain (we set our own).
ALWAYS_STRIP = frozenset(h.lower() for h in (OWNER_HEADER_NAME, AUTH_HEADER_NAME, "x-forwarded-for"))

logging.basicConfig(
    level=os.environ.get("AUTH_PROXY_LOG_LEVEL", "INFO"),
    format="[auth-proxy] %(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("auth_proxy")


def _resolve_owner_username() -> str:
    raw = os.environ.get("OPENHOST_OWNER_USERNAME", "").strip()
    if raw and _VALID_USERNAME_RE.match(raw):
        return raw
    if raw:
        log.warning("OPENHOST_OWNER_USERNAME=%r is not a valid username; using %r", raw, FALLBACK_OWNER_USERNAME)
    return FALLBACK_OWNER_USERNAME


OWNER_USERNAME = _resolve_owner_username()
log.info("Mapping OpenHost owner to Navidrome username %r", OWNER_USERNAME)


class AuthProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openhost-navidrome-authproxy"

    def log_message(self, fmt: str, *args: object) -> None:  # noqa: A003
        log.debug("%s - %s", self.address_string(), fmt % args)

    def _handle(self) -> None:
        is_owner = self.headers.get(OWNER_HEADER_NAME, "").strip().lower() == "true"

        forwarded_host = self.headers.get("X-Forwarded-Host")
        forwarded_proto = self.headers.get("X-Forwarded-Proto", "https")

        # Build the upstream header list.
        out_headers: list[tuple[str, str]] = []
        for key, value in self.headers.items():
            kl = key.lower()
            if kl in HOP_BY_HOP or kl in ALWAYS_STRIP or kl == "content-length":
                continue
            out_headers.append((key, value))

        # Host Navidrome should believe it is serving as (for URL generation).
        # Navidrome rejects requests with no Host header (400), so always set
        # one: the forwarded host for real traffic, else the inbound Host
        # (e.g. the router's liveness probe), else the upstream address.
        host_val = forwarded_host or self.headers.get("Host") or f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"
        out_headers.append(("Host", host_val))
        # Pin the forwarded chain to loopback so Navidrome's reverse-proxy
        # auth treats the request as coming from a trusted source.
        out_headers.append(("X-Forwarded-For", "127.0.0.1"))
        out_headers.append(("X-Forwarded-Proto", forwarded_proto))
        if is_owner:
            out_headers.append((AUTH_HEADER_NAME, OWNER_USERNAME))

        # Read request body (if any).
        body = None
        length = self.headers.get("Content-Length")
        if length:
            try:
                body = self.rfile.read(int(length))
            except (ValueError, OSError):
                self.send_error(400, "Invalid request body")
                return

        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=600)
            conn.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            for k, v in out_headers:
                conn.putheader(k, v)
            if body is not None:
                conn.putheader("Content-Length", str(len(body)))
            conn.endheaders()
            if body:
                conn.send(body)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            log.warning("upstream error: %s", exc)
            try:
                self.send_error(502, "Upstream error")
            except OSError:
                pass
            return

        # Relay status + headers, streaming the body so audio/range responses
        # aren't buffered in memory.
        try:
            self.send_response_only(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            self.end_headers()
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (OSError, http.client.HTTPException) as exc:
            log.debug("client/upstream disconnect during relay: %s", exc)
        finally:
            conn.close()

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle


def main() -> None:
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), AuthProxyHandler)
    httpd.daemon_threads = True
    # Fail fast if the listen socket can't bind.
    try:
        httpd.server_bind  # noqa: B018
    except OSError as exc:  # pragma: no cover
        log.error("cannot bind %s:%d: %s", LISTEN_HOST, LISTEN_PORT, exc)
        sys.exit(1)
    log.info("listening on %s:%d -> %s:%d", LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    socket.setdefaulttimeout(None)
    main()
