Navidrome music server for Cloud in a Bottle. Runs as a single Docker container:

- Navidrome latest (web-based music streamer, like a personal Spotify)
- Embedded SQLite database, no external dependencies
- Subsonic API compatible (works with DSub, Submariner, play:Sub, Symfonium, etc.)
- Very low resource usage (~50MB RAM)

## Deploying

Deploy via the Cloud in a Bottle router dashboard -- point it at this repo. The app will be available at `{app_name}.{zone_domain}` (e.g. `navidrome.zack.host.imbue.com`).

## First-time setup

1. Visit the app URL -- Navidrome will show a registration page
2. Create your admin account (first user registered becomes admin)
3. Upload music to the `music/` directory in the app's persistent data

## Adding music

Music files go in `$OPENHOST_APP_DATA_DIR/music/`. You can upload files via any method that can write to the Cloud in a Bottle app data directory. Navidrome automatically scans for new files every hour.

## Data

All persistent data lives in `$OPENHOST_APP_DATA_DIR/`:
- `data/` -- Navidrome database, cache, transcoding cache
- `music/` -- your music library

## Access control

This app is fully private. There are no public paths in `openhost.toml`, so all requests require Cloud in a Bottle authentication.

## Resources

Needs ~256MB RAM and 0.25 CPU cores. The container image is ~75MB.

## Client apps

Because all routes are gated by Cloud in a Bottle auth, direct Subsonic client apps may not work unless you later expose API paths publicly.

## Files

- `Dockerfile` -- extends the official Navidrome image (Alpine), adds Caddy
- `start.sh` -- configures data/music dirs, starts Caddy + Navidrome
- `Caddyfile` -- rewrites Host header from X-Forwarded-Host
- `openhost.toml` -- Cloud in a Bottle app manifest

## License

Navidrome is licensed under the GNU General Public License v3.0 (GPL-3.0). The container image built from this repo is distributed under that license. The packaging files original to this repository are additionally available under the MIT License. See LICENSE and NOTICE for details.
