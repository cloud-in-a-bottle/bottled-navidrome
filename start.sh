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
export ND_LOGLEVEL=debug
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
# header can't be spoofed.
#
# Navidrome refuses to honour reverse-proxy auth until at least one admin
# user exists (otherwise it forces its interactive "create admin" wizard),
# so on first boot we seed an admin row for the owner.  After that, ext-auth
# logs them straight in under that account.
#
# OPENHOST_REVERSE_PROXY_USER is the username Caddy stamps.  We resolve it
# from the OpenHost owner username (sanitised to Navidrome's allowed
# characters) and fall back to "admin" when unset/empty so we never seed a
# blank account.
RAW_OWNER="${OPENHOST_OWNER_USERNAME:-}"
SAFE_OWNER="$(printf '%s' "$RAW_OWNER" | tr -cd 'A-Za-z0-9._-')"
if [ -z "$SAFE_OWNER" ]; then
    SAFE_OWNER="admin"
fi
# New ExtAuth config keys (Navidrome >= 0.59); the ReverseProxy* keys are
# the deprecated aliases kept for older builds.
export ND_EXTAUTH_USERHEADER="Remote-User"
export ND_EXTAUTH_TRUSTEDSOURCES="127.0.0.1/32,::1/128"
export ND_REVERSEPROXYUSERHEADER="Remote-User"
# Only the in-container Caddy (loopback) is trusted to set Remote-User.
export ND_REVERSEPROXYWHITELIST="127.0.0.1/32,::1/128"
echo "Navidrome SSO: owner auto-login as '$OPENHOST_REVERSE_PROXY_USER' via reverse-proxy auth"

DB_FILE="$DATA_DIR/navidrome.db"

# Returns 0 if an admin user already exists in the Navidrome DB.
admin_exists() {
    [ -f "$DB_FILE" ] || return 1
    local n
    n="$(sqlite3 "$DB_FILE" "SELECT count(*) FROM user WHERE is_admin = 1;" 2>/dev/null || echo 0)"
    [ "$n" -ge 1 ] 2>/dev/null
}

# Seed an admin user matching the OpenHost owner so ext-auth can log them in
# without the create-admin wizard.  Idempotent: only inserts when the user
# table is empty of admins.
seed_owner_admin() {
    local now uid pw
    now="$(date -u +"%Y-%m-%d %H:%M:%S")"
    uid="$(cat /proc/sys/kernel/random/uuid)"
    # The owner authenticates via the trusted reverse-proxy header, never this
    # password, so a throwaway random value is fine (and avoids a blank one).
    pw="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)"
    sqlite3 "$DB_FILE" <<SQL
INSERT OR IGNORE INTO user (id, user_name, name, email, password, is_admin, created_at, updated_at)
VALUES ('$uid', '$SAFE_OWNER', '$SAFE_OWNER', '', '$pw', 1, '$now', '$now');
SQL
    echo "Navidrome SSO: seeded admin user '$SAFE_OWNER'"
}

if ! admin_exists; then
    echo "Navidrome SSO: no admin user yet — seeding owner admin (first boot)"
    # Phase 1: boot Navidrome briefly so it creates and migrates the DB.
    /app/navidrome >/tmp/nd-init.log 2>&1 &
    ND_INIT_PID=$!
    # Wait (up to ~60s) for the user table to exist, then seed.
    i=0
    while [ $i -lt 60 ]; do
        if [ -f "$DB_FILE" ] && [ -n "$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='user';" 2>/dev/null)" ]; then
            break
        fi
        i=$((i + 1))
        sleep 1
    done
    seed_owner_admin
    # Stop the init instance; phase 2 below runs Navidrome for real.
    kill "$ND_INIT_PID" 2>/dev/null || true
    wait "$ND_INIT_PID" 2>/dev/null || true
fi

# Render the Caddy config with the resolved owner username baked in, then
# run Caddy against the rendered copy.  (Caddy's {$ENV} substitution proved
# unreliable for a value exported at container start.)
RENDERED_CADDYFILE="/tmp/Caddyfile.rendered"
sed "s/__OWNER_USERNAME__/${SAFE_OWNER}/g" /app/Caddyfile > "$RENDERED_CADDYFILE"

# Start Caddy in background — port 3000 -> Navidrome on 4533
caddy run --config "$RENDERED_CADDYFILE" &
echo "Caddy started (owner reverse-proxy user: $SAFE_OWNER)"

# Start Navidrome
echo "Starting Navidrome..."
exec /app/navidrome
