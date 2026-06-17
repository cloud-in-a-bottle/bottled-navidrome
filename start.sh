#!/bin/sh
set -e

# OpenHost mounts persistent storage at OPENHOST_APP_DATA_DIR.
# Navidrome needs /data (DB + cache) and /music (music files).
# We store both under the persistent directory.
PERSIST="${OPENHOST_APP_DATA_DIR:-/data}"

DATA_DIR="$PERSIST/data"
MUSIC_DIR="$PERSIST/music"

mkdir -p "$DATA_DIR" "$MUSIC_DIR"

# Derive base URL from OpenHost environment variables
if [ -n "$OPENHOST_ZONE_DOMAIN" ]; then
    APP_SUBDOMAIN="${OPENHOST_APP_NAME:-navidrome}"
    DOMAIN_NAME="${APP_SUBDOMAIN}.${OPENHOST_ZONE_DOMAIN}"

    case "$OPENHOST_ZONE_DOMAIN" in
        lvh.me|*.lvh.me|localhost|*.localhost)
            ROUTER_PORT=""
            if [ -n "$OPENHOST_ROUTER_URL" ]; then
                ROUTER_PORT=$(echo "$OPENHOST_ROUTER_URL" | sed -n 's/.*:\([0-9]*\)$/\1/p')
            fi
            BASE_URL="http://${DOMAIN_NAME}${ROUTER_PORT:+:$ROUTER_PORT}"
            ;;
        *)
            BASE_URL="https://${DOMAIN_NAME}"
            ;;
    esac
else
    BASE_URL=""
fi

echo "Navidrome starting: data=$DATA_DIR music=$MUSIC_DIR base_url=$BASE_URL"

# Configure Navidrome via environment variables
export ND_DATAFOLDER="$DATA_DIR"
export ND_MUSICFOLDER="$MUSIC_DIR"
export ND_PORT=4533
export ND_ADDRESS=0.0.0.0
export ND_BASEURL=""
export ND_LOGLEVEL=info
export ND_SCANSCHEDULE=1h
export ND_SESSIONTIMEOUT=168h
export ND_ENABLESHARING=true
export ND_ENABLETRANSCODINGCONFIG=true

# --- OpenHost single sign-on --------------------------------------------
# Navidrome auto-logs the OpenHost owner in via reverse-proxy auth: the
# Caddy front-end (see Caddyfile) injects `Remote-User: <owner>` only when
# the OpenHost router stamps `X-OpenHost-Is-Owner: true`.  Navidrome trusts
# that header but ONLY from the local Caddy process (the whitelist below),
# and Caddy always strips any client-supplied Remote-User first, so the
# header can't be spoofed.  The first auto-created user becomes the admin.
#
# OPENHOST_REVERSE_PROXY_USER is the username Caddy stamps.  We resolve it
# from the OpenHost owner username (sanitised to Navidrome's allowed
# characters) and fall back to "admin" when unset/empty so reverse-proxy
# auto-registration can't create a blank account.
RAW_OWNER="${OPENHOST_OWNER_USERNAME:-}"
SAFE_OWNER="$(printf '%s' "$RAW_OWNER" | tr -cd 'A-Za-z0-9._-')"
if [ -z "$SAFE_OWNER" ]; then
    SAFE_OWNER="admin"
fi
export OPENHOST_REVERSE_PROXY_USER="$SAFE_OWNER"
export ND_REVERSEPROXYUSERHEADER="Remote-User"
# Only the in-container Caddy (loopback) is trusted to set Remote-User.
export ND_REVERSEPROXYWHITELIST="127.0.0.1/32,::1/128"
echo "Navidrome SSO: owner auto-login as '$OPENHOST_REVERSE_PROXY_USER' via reverse-proxy auth"

# Start Caddy in background — port 3000 -> Navidrome on 4533
caddy run --config /app/Caddyfile &
echo "Caddy started"

# Start Navidrome
echo "Starting Navidrome..."
exec /app/navidrome
