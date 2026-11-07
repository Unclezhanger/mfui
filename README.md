<p align="center">
  <img src="public/logo.png" width="96" alt="mfui logo">
</p>

<h1 align="center">mfui</h1>

<p align="center">
  <strong>Web UI + Docker for the musicfeed download kernel — YouTube Music to your self-hosted library, with correct covers & tags.</strong>
</p>

<p align="center">
  <a href="#-quick-start">Install</a> ·
  <a href="#-using-mfui">Using mfui</a> ·
  <a href="#-how-it-works">How it works</a> ·
  <a href="#-faq">FAQ</a> ·
  <a href="https://github.com/Unclezhanger/musicfeed">CLI edition</a>
</p>

<p align="center">
  <a href="https://github.com/Unclezhanger/mfui/releases"><img src="https://img.shields.io/badge/release-v4.6.0-success.svg" alt="Release v4.6.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <a href="https://github.com/Unclezhanger/musicfeed"><img src="https://img.shields.io/badge/kernel-musicfeed%20v4.1-orange.svg" alt="kernel"></a>
  <img src="https://img.shields.io/badge/python-free-success.svg" alt="python-free">
  <img src="https://img.shields.io/badge/platform-linux%20%7C%20NAS%20%7C%20Docker-lightgrey.svg" alt="platform">
</p>

---

## 🤔 What is mfui?

mfui is a self-hosted web interface for downloading music from YouTube and
YouTube Music into the exact shape a music server expects. If you run
**Navidrome**, **Jellyfin**, **Plex** or any Subsonic-compatible server,
mfui takes care of the three things that normally make downloaded music
look broken in your library:

| Problem | What mfui does |
| --- | --- |
| Album covers padded to 16:9, wrong or missing art | Three cover strategies chosen per track — 1:1 center-crop for tagged YTM audio, unified album art for albums, original-aspect thumbnails for music videos |
| Missing / wrong ID3 tags, artists split across entries | Writes full tags including `album_artist`, splits multi-artist strings (`feat.` / `&`), fills album from real metadata when available |
| Filenames like `【MV】【動態歌詞】Song Name (Official Audio)` | A title-extraction engine rebuilds clean `artist - title` names from the polluted title + channel |

It is built on the
[musicfeed](https://github.com/Unclezhanger/musicfeed) bash kernel — the CLI
edition shares the same engine and the same `mf_config.sh`.

> **v4.5 runs on the python-free musicfeed v4.1 kernel.** All tagging, cover
> handling, JSON parsing and title extraction are done with `ffmpeg`, `jq`
> and plain Bash — there is no Python, no venv and no mutagen in the
> container.

## 📸 Screenshots

**Dashboard** — dependencies, current config and recent jobs at a glance:

![Dashboard](docs/screenshots/dashboard.png)

**Paste a link → preview the track list → pick your tracks** (metadata and
MV badges tell you upfront how each track will be treated):

![Track selection](docs/screenshots/download-track-selection.png)

**Configure** — artist folder, subfolder on/off, album artist, cover mode
(unified / per-track), Opus or M4A:

![Configure](docs/screenshots/download-configure.png)

**Live progress** — real-time log and a progress bar that reaches 100%:

![Progress](docs/screenshots/download-progress.png)

Completed, with the file renamed, tagged and the cover embedded:

![Completed](docs/screenshots/download-completed.png)

**History** keeps every job (filter running / completed / failed), each with
a full log you can re-open:

![History](docs/screenshots/history.png)

**Settings** — music root with a folder-tree browser, default artist folder,
hidden-folder checklist, interface language (8 languages):

![Settings](docs/screenshots/settings.png)

Installable as a **PWA** on your phone (share YouTube links straight into
the queue):

<p align="center">
  <img src="docs/screenshots/mobile-dashboard.png" width="320" alt="Mobile dashboard">
</p>

The end result in **Navidrome** — one album (unified cover) plus four MV
singles (per-track covers), everything tagged:

![Navidrome result](docs/screenshots/navidrome-result.png)

## 🚀 Quick Start

### Docker (recommended)

You need [Docker](https://docs.docker.com/engine/install/) with the
compose plugin. That's it — no Node.js, no Python, no yt-dlp to install.

```bash
mkdir mfui && cd mfui
curl -O https://raw.githubusercontent.com/Unclezhanger/mfui/main/docker-compose.yml
```

Edit `docker-compose.yml` and point the music volume at your library:

```yaml
volumes:
  - /home/youruser/navidrome/music:/music   # <-- your music directory
```

Then start:

```bash
docker compose up -d
```

Open **http://localhost:3011** — on first start the container automatically
creates the database, seeds a default config and downloads the standalone
yt-dlp binary into the `/config` volume (auto-updated on every start;
disable with `MF_YTDLP_AUTOUPDATE=0`). No Python or venv is involved.

The kernel's yt-dlp solves YouTube's JS challenges through a JS runtime
(minimum **Node.js 22**). The image ships with Node 22, and a **node
sidecar** covers the gap while the image ages: if the baked node falls
behind the pinned major line's latest release, the entrypoint downloads an
official binary (SHA256-verified) into the `/config` volume and uses it for
the app, job-runner and download workers — no image rebuild needed. It only
auto-updates **within** the pinned major; to move to a newer major set
`MF_NODE_MAJOR` in `/config/mf_config.sh` (e.g. `"24"`) and restart. Disable
with `MF_NODE_AUTOUPDATE=0`; a rebuilt image that catches up removes the
stale sidecar automatically.

Notes:

- The web UI listens on **host port 3011** (container-internal 3010) so it
  can coexist with a bare-metal mfui installed via `start.sh` on 3010.
- The download services run as `MFUI_UID`/`MFUI_GID` (default `1000:1000`).
  Downloaded files in your music library are owned by that user — set the
  two variables in `docker-compose.yml` if your user has a different UID.
- All state (database, logs, config, yt-dlp binary) lives in named volumes
  (`mfui-db`, `mfui-log`, `mfui-config`) and survives container upgrades.

<details>
<summary>Prefer <code>docker run</code>?</summary>

```bash
docker run -d --name mfui --restart unless-stopped \
  -p 3011:3010 \
  -e MF_YTDLP_AUTOUPDATE=1 \
  -e MFUI_UID=1000 -e MFUI_GID=1000 \
  -v /home/youruser/navidrome/music:/music \
  -v mfui-db:/app/db -v mfui-log:/app/musicfeed/log \
  -v mfui-config:/config \
  ghcr.io/unclezhanger/mfui:latest
```

</details>

<details>
<summary>Prefer to build locally?</summary>

```bash
git clone https://github.com/Unclezhanger/mfui.git
cd mfui
docker compose up -d --build
```

</details>

### Bare metal (no Docker)

Requires **Node.js ≥ 22**, `ffmpeg`, `jq`, `curl` and bash 4+
(macOS: `brew install bash` first; Node 22 is the kernel's yt-dlp
JS-runtime minimum — `setup.sh` offers a project-local Node 22 if your
system one is older):

```bash
git clone https://github.com/Unclezhanger/mfui.git
cd mfui
bash setup.sh         # dependency check + one-click install, database, .env
bash start.sh --prod  # production mode on http://localhost:3010
```

- `--prod` builds the standalone bundle once, then starts instantly. Use it
  for daily driving — plain `bash start.sh` is the developer mode
  (localhost only).
- Downloads are written by your own user, so your library stays manageable
  with normal file tools.
- To stop: `bash stop.sh`. To update: `git pull`, then repeat
  `start.sh --prod` — it detects the stale build and offers to rebuild.
- The bare-metal install is also **dependency-clean**: `setup.sh` can drop
  static `ffmpeg`/`jq` and a standalone `yt-dlp` straight into the project
  folder — delete the folder to uninstall, nothing touches your system.

> No Python required — the v4.5 kernel uses `ffmpeg` + `jq` + Bash only.
> yt-dlp is a standalone binary kept in `musicfeed/bin/`.

## 📖 Using mfui

1. **Open the dashboard.** The dependency card should read `5/5` — if
   something is missing, the page tells you the exact command to install it.
2. **Paste one or more links** (up to 10, one per line) into the download
   page. Markdown links and trailing punctuation are tolerated. Supported:
   YTM albums (share **or** address-bar links), YTM radios, YouTube
   playlists, singles and music videos.
3. **Preview & pick tracks.** Each track shows a badge: 🟢 *Metadata* means
   real YTM metadata will be used; 🟡 *MV* means the video has no music
   metadata and you'll get manual input fields (pre-filled from the title).
4. **Configure.** Choose the artist folder (or create a new one), whether to
   keep an album subfolder, the cover mode, and the audio format.
5. **Download.** Watch the live log; every job is kept in **History** with
   its complete log, and the track list shows a per-track
   metadata/MV badge so you always know how a file will be named.
6. **Let your server scan.** Navidrome picks the new files up automatically
   — covers, `album_artist` and clean filenames included.

### Multi-link queue

Paste several links at once: mfui walks you through each one (select tracks
→ configure) and then downloads them **sequentially** with one merged live
log and an aggregated progress bar ("queue 2/5").

### PWA (phone)

Visit the Web UI from your phone browser and use *Add to Home Screen*.
mfui installs as an app and registers a **share target** — in the YouTube
app, tap *Share → mfui* and the link lands in the download page.

## 🧭 How it works

```
Browser ──▶ Next.js (:3011 host → :3010 container)
              ├── pages & REST API
              ├── /api/proxy/*  ──▶  job-runner (127.0.0.1:3001, not exposed)
              │                      └── spawns musicfeed kernel (bash)
              │                            └── yt-dlp + ffmpeg (standalone binaries)
              └── /socket.io/*  ──▶ live progress & logs
```

One container, two processes, supervised by `tini`. All download work
happens in the bash kernel — the web layer only configures and observes it.

Want the terminal version of the same engine? The
[musicfeed CLI edition](https://github.com/Unclezhanger/musicfeed) runs the
identical kernel with an interactive TUI — no Node.js required.

## ⚙️ Configuration

Everything on the **Settings** page maps to `mf_config.sh` (the kernel's
config file):

| Setting | Variable | Meaning |
| --- | --- | --- |
| Music root | `MF_BASE_DIR` | Every artist folder is created here |
| Default artist folder | `MF_DEFAULT_ARTIST_DIR` | Pre-selected folder in the download form |
| Audio format | `MF_AUDIO_FORMAT` | Default format pre-selected in the download form (still changeable per download): `opus` (smaller, recommended) or `m4a` (iOS/Apple) |
| Hidden folders | `MF_HIDDEN_DIRS` | Folders hidden from the artist-folder list |

The **interface language** (8 languages) is stored in your browser.

The **yt-dlp channel** is fixed to `stable` in the Docker image. If
downloads start failing after a YouTube change, just restart the container
— the entrypoint re-checks yt-dlp on every start and pulls the latest
stable build automatically:

```bash
docker restart mfui
```

Advanced users who want the `nightly` channel (faster anti-bot fixes) can
switch it in a bare-metal install, or in Docker by setting `MF_YTDLP_CHANNEL`
in `/config/mf_config.sh` and restarting the container:

```bash
docker exec mfui sed -i 's/^MF_YTDLP_CHANNEL=.*/MF_YTDLP_CHANNEL="nightly"/' /config/mf_config.sh
docker restart mfui
```

Saving on the Settings page keeps this value. (If you disabled auto-update
with `MF_YTDLP_AUTOUPDATE=0`, also delete `/config/bin/yt-dlp*` before the
restart so the new channel's build is downloaded.)

The **node sidecar** (container only) works the same way: the entrypoint
keeps an official Node.js in `/config/node` only while the image's baked
node is behind the latest release of the pinned major line (`MF_NODE_MAJOR`,
default `22`), and skips the download once a rebuilt image catches up.
Normally you never touch it; to move to a newer major line or force a
refresh, set `MF_NODE_MAJOR` in `/config/mf_config.sh` (e.g. `"24"`) and
restart, and to drop it entirely set `MF_NODE_AUTOUPDATE=0` and delete
`/config/node`:

## ❓ FAQ

**Why does the container listen on 3011 and the bare-metal install on 3010?**
So both can coexist on the same machine. If you only use one of them, any
free port works — the container publishes `3011:3010`; the bare-metal
default is `3010` (`MF_PORT_NEXT` to change).

**Why are downloads owned by a different user / root?**
The container's download services run as `MFUI_UID`/`MFUI_GID` (default
`1000:1000`) — files are owned by that user. If your library user has a
different UID, set the two variables in `docker-compose.yml`. Bare-metal
downloads are owned by the user running `start.sh`.

**Downloads fail with 403 / "Sign in to confirm…"**
YouTube throttles anonymous downloads from datacenter IPs sometimes.

- **Docker:** just restart the container — the entrypoint re-checks yt-dlp
  on every start and pulls the latest stable build. The nightly channel is
  intentionally not exposed here.
- **Bare metal:** re-run `bash musicfeed/mf_setup.sh` and pick
  **Update to latest stable** or **Switch to nightly**.

**Optional: run the yt-dlp nightly build (bare metal only).** Nightly
releases track YouTube changes more closely and can fix breakage days
before the stable release. In the Docker image the channel is fixed to
`stable` — just restart the container to pick up the latest stable build.
For bare metal, run `bash musicfeed/mf_setup.sh` and pick **Switch to
NIGHTLY** in the yt-dlp step.

**The UI says a dependency is missing**
Open the Dashboard — it lists exactly what's missing and the command to
install it. In Docker everything is bundled, so a missing dependency there
usually means the `/config` volume was wiped; just restart the container.

**yt-dlp is missing right after the first start (Docker)**
The container downloads the standalone yt-dlp from GitHub on first start
(with retries and timeouts). If the network was not ready, the download can
fail while the web UI still starts. Check
`docker logs mfui 2>&1 | grep entrypoint` — a `yt-dlp download failed` line
confirms it — then `docker restart mfui` to retry. If the Dashboard still
shows yt-dlp as missing although the log shows a successful download, wait a
few seconds and reload the page (the first launch of the binary can be slow).

**How do I see the database (SQL) queries in the log? (debugging)**
They are off by default because they flood the log. Set
`MF_PRISMA_LOG_QUERY=1` to turn them on: in Docker add it under
`environment:` in `docker-compose.yml` (or `-e MF_PRISMA_LOG_QUERY=1` with
`docker run`) and recreate the container with `docker compose up -d`; on bare
metal start with `MF_PRISMA_LOG_QUERY=1 bash start.sh` (add `--prod` for
production mode). Remove it again when you are done.

**Where do my files go?**
Into `<music root>/<artist folder>/[subfolder]/`, e.g.
`/music/Ed Sheeran/Ed Sheeran - Shape of You.opus`. The artist folder and
subfolder are chosen on the config page; with the subfolder **off**, files
go straight into the artist folder.

**How do I update?**

```bash
# Docker
cd mfui && docker compose pull && docker compose up -d

# Bare metal
cd mfui && git pull && bash start.sh --prod   # offers to rebuild
```

All data (database, logs, config, yt-dlp binary) survives updates.

**Does bare metal work on macOS?**
Not tested yet. On macOS please use the **Docker** install (Docker Desktop):
that path is tested and works. The bare-metal scripts do contain macOS
handling, but it has not been verified on a real Mac, so treat it as
experimental. `start.sh`/`stop.sh` detect that macOS has no `setsid` and try
to emulate it via perl. Two macOS specifics:

- **macOS 11 (Big Sur) or older:** the `esbuild` binary bundled with `tsx`
  4.x is built for macOS 12+ and fails with a dyld error. `setup.sh` detects
  this and installs the job-runner dependencies with `tsx@3.14.0` pinned.
- **Finding your LAN IP:** use `ipconfig getifaddr en0` (Linux's
  `hostname -I` doesn't exist on macOS).

## 🌍 Languages

English (default), 中文, Deutsch, Español, Français, 日本語,
Português (Brasil), Русский — switch in **Settings → Interface language**.

## ⚠️ Disclaimer

For personal and educational use only. Please respect copyright laws in
your region. The author assumes no liability for any misuse.

## 📄 License

MIT License © 2026 [Unclezhanger](https://github.com/Unclezhanger)
