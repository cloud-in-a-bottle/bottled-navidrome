# bottled-navidrome

[Navidrome](https://github.com/navidrome/navidrome) is a music server and
streamer with a web UI and Subsonic API support. This repository packages it as
a Cloud in a Bottle app.

## What you get

- Navidrome running on `https://navidrome.<zone>/`.
- Public: anyone with the URL can reach the app. The owner is auto-logged in
  via Cloud in a Bottle SSO; others see Navidrome's login.
- Subsonic API compatible (works with DSub, Submariner, play:Sub, Symfonium,
  and other Subsonic/OpenSubsonic clients).
- Share links for tracks and albums (accessible without login when sharing is
  enabled).
- Transcoding configuration exposed in the admin panel.
- Low resource usage.

## Usage

Open `https://navidrome.<zone>/`. As the Cloud in a Bottle owner you are
logged in automatically as admin. Upload music files into the music directory
(see Data below), then trigger a library scan from Settings or wait for the
hourly automatic scan.

Subsonic clients connect to the same URL with the owner's Navidrome username
and password. A separate Navidrome password can be set in the user profile
settings if needed for clients.

To invite other users, create accounts from the Users admin page. They log in
at the Navidrome login form with their own credentials.

## Data

All persistent data lives under `$OPENHOST_APP_DATA_DIR/`:

- `data/`: Navidrome database, cache, transcoding cache
- `music/`: your music library (upload files here)

## Caveats

- The music directory starts empty. You need to add music files for the app to
  be useful.
- Navidrome scans for new music every hour. Trigger a manual scan from Settings
  if you do not want to wait.
- Sharing requires Navidrome v0.49+. Share links work anonymously because the
  app is public.

## Resources

About 256 MB RAM and 0.25 CPU cores.

## License

Navidrome is licensed under the GNU General Public License v3.0 (GPL-3.0). The
container image built from this repo is distributed under that license. The
packaging files original to this repository are additionally available under
the MIT License. See LICENSE and NOTICE for details.
