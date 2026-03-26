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

# Start Caddy in background — port 3000 -> Navidrome on 4533
caddy run --config /app/Caddyfile &
echo "Caddy started"

# Start Navidrome
echo "Starting Navidrome..."
exec /app/navidrome
