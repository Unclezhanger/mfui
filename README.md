<p align="center">
  <img src="public/logo.png" width="96" alt="mfui logo">
</p>

<h1 align="center">mfui</h1>

<p align="center">
  <strong>Web UI + Docker for the musicfeed download kernel — YouTube Music to your self-hosted library, with correct covers & tags.</strong>
</p>

<p align="center">
  <a href="#-quick-start">Install</a> ·
  <a href="https://github.com/Unclezhanger/musicfeed">CLI edition</a> ·
  <a href="#-how-it-works">How it works</a> ·
  <a href="#-languages">8 languages</a>
</p>

---

## ✨ What is mfui

Paste a YouTube / YouTube Music link, pick your tracks, download — with the
metadata, cover art and folder structure a music server like **Navidrome**,
**Jellyfin** or **Plex** expects. Built on the
[musicfeed](https://github.com/Unclezhanger/musicfeed) bash kernel.

- 🖼️ **Cover art that looks right** — 1:1 center-crop for YTM tracks, unified
  album cover for albums, original aspect for music videos
- 🏷️ **Correct ID3 tags** — `album_artist`, multi-artist splitting (`feat.` /
  `&`), clean song titles extracted from polluted video titles
- 📃 **Multi-link queue** — paste up to 10 links, configure each, download
  sequentially with unified progress and a merged live log
- 📱 **PWA** — install on your phone, share YouTube links straight into the
  download queue
- 🌍 **8 interface languages** — English, 中文, Deutsch, Español, Français,
  日本語, Português (BR), Русский
- 🐳 **Single-container Docker** — music directory + a few volumes, done

## 🚀 Quick Start (Docker, recommended)

```bash
mkdir mfui && cd mfui
curl -O https://raw.githubusercontent.com/Unclezhanger/mfui/main/docker-compose.yml
# edit: point the music volume at your library
docker compose up -d
```

Open **http://localhost:3010** — first run auto-installs yt-dlp into a
persistent venv (auto-update on every start, disable with
`MF_YTDLP_AUTOUPDATE=0`), creates the database and seeds a default config.

**Volumes:** your music library at `/music`, plus named volumes for the
database, logs, config and the venv — safe to upgrade or recreate the
container.

<details>
<summary>Prefer to build locally?</summary>

```bash
git clone https://github.com/Unclezhanger/mfui.git
cd mfui
docker build -t mfui .
docker run -d -p 3010:3010 -v /path/to/music:/music mfui
```

</details>

## 💻 Without Docker (advanced)

Requires Node.js ≥ 20, ffmpeg, python3 (+ venv) and bash 4+:

```bash
git clone https://github.com/Unclezhanger/mfui.git
cd mfui
bash setup.sh        # deps check, config, database
bash start.sh --prod # production mode on http://localhost:3010
```

Prefer a pure command-line workflow? The
[musicfeed CLI edition](https://github.com/Unclezhanger/musicfeed) runs the
same kernel with an interactive TUI — no Node.js required.

## ⚙️ How it works

```
Browser ──▶ Next.js (:3010)
              ├── pages & REST API
              ├── /api/proxy/*  ──▶  job-runner (127.0.0.1:3001, not exposed)
              │                      └── spawns musicfeed kernel (bash)
              │                            └── yt-dlp + ffmpeg (project venv)
              └── /socket.io/*  ──▶ live progress & logs
```

One container, two processes, supervised by `tini`. All download work happens
in the bash kernel — the web layer only configures and observes it.

## 🌍 Languages

The interface ships in English (default), 中文, Deutsch, Español, Français,
日本語, Português (Brasil) and Русский — switch anytime in **Settings →
Interface language**. Job logs follow `MF_LANG` in `mf_config.sh`.

## 📄 License

MIT License © 2026 [Unclezhanger](https://github.com/Unclezhanger)

For personal and educational use only. Please respect copyright laws in your
region.
