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
# A small Python auth-proxy sidecar (auth_proxy.py) fronts Navidrome on
# port 3000.  For owner requests (router-stamped X-OpenHost-Is-Owner: true)
# it forwards `Remote-User: <owner>` so Navidrome's reverse-proxy auth signs
# the owner in under their real OpenHost username; everyone else is
# forwarded without it and uses Navidrome's normal login.
#
# Navidrome only honours Remote-User when the request's X-Forwarded-For
# client is in its trusted sources, so the proxy pins X-Forwarded-For to
# 127.0.0.1 (the only address we trust).  Navidrome also refuses
# reverse-proxy auth until an admin user exists (otherwise it forces the
# interactive "create admin" wizard), so on first boot we seed an admin row
# for the owner.
#
# SAFE_OWNER is the username we seed; the proxy resolves the same value from
# OPENHOST_OWNER_USERNAME independently.  Fall back to "admin" when
# unset/empty so we never seed a blank account.
RAW_OWNER="${OPENHOST_OWNER_USERNAME:-}"
SAFE_OWNER="$(printf '%s' "$RAW_OWNER" | tr -cd 'A-Za-z0-9._-')"
if [ -z "$SAFE_OWNER" ]; then
    SAFE_OWNER="admin"
fi
# New ExtAuth config keys (Navidrome >= 0.59); the ReverseProxy* keys are
# the deprecated aliases kept for older builds.  Trust only loopback — the
# auth-proxy presents every owner request as coming from 127.0.0.1.
export ND_EXTAUTH_USERHEADER="Remote-User"
export ND_REVERSEPROXYUSERHEADER="Remote-User"
export ND_EXTAUTH_TRUSTEDSOURCES="127.0.0.1/32,::1/128"
export ND_REVERSEPROXYWHITELIST="127.0.0.1/32,::1/128"
echo "Navidrome SSO: owner auto-login as '$SAFE_OWNER' via reverse-proxy auth"

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
    local now uid
    now="$(date -u +"%Y-%m-%d %H:%M:%S")"
    uid="$(cat /proc/sys/kernel/random/uuid)"
    # Leave the password empty: the owner authenticates via the trusted
    # reverse-proxy header, never a password.  An empty password skips
    # Navidrome's at-rest password decryption (a non-empty plaintext would
    # fail AES-GCM decryption and error on login).
    sqlite3 "$DB_FILE" <<SQL
INSERT OR IGNORE INTO user (id, user_name, name, email, password, is_admin, created_at, updated_at)
VALUES ('$uid', '$SAFE_OWNER', '$SAFE_OWNER', '', '', 1, '$now', '$now');
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

# Start the OpenHost auth-proxy sidecar — listens on :3000, forwards to
# Navidrome on :4533, injecting Remote-User for owner requests.
python3 /app/auth_proxy.py &
echo "Auth-proxy started (owner reverse-proxy user: $SAFE_OWNER)"

# Start Navidrome
echo "Starting Navidrome..."
exec /app/navidrome
