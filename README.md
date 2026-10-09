# LiveWall — Live Wallpaper for Mac

A lightweight live/video wallpaper app for macOS, built in Swift + AppKit/SwiftUI.
Plays looping muted videos behind your desktop icons, with a Liquid Glass control
panel, a Dynamic Island for live activities, and a companion web gallery of openly
licensed 4K wallpapers.

![LiveWall control panel](docs/screenshot.png)

## Features

**Wallpaper**
- Looping **video wallpapers** rendered at desktop level (behind icons, click-through)
- **Multi-monitor**: span one continuous video across all screens, or play per screen
- **Fill / Fit / Stretch** scaling, with a live miniature of your real monitor layout
  showing exactly what each setting does
- **Per-video playback speed** (0.25×–1.5×), remembered for each wallpaper and applied live
- Setting changes **morph in place** and new videos **cross-fade** — no restart or black flash
- **Pauses automatically** when the wallpaper can't be seen: a fullscreen app's Space,
  windows covering every screen, or displays asleep (a fullscreen app on one display
  leaves the other playing)
- **Launch at login** — on by default, switchable from the menu bar

**Control panel**
- Liquid Glass design (macOS 26) with a live "Now Playing" hero, search, and a
  calm "golden hour" brand: one amber accent for what's playing, selected or primary
- Clean artwork tiles in the style of Apple's media apps; hover tilts a tile and
  plays a live preview (hover effects pause while scrolling, so scrolling stays smooth)
- **Tags**: a sidebar filters the library by tag; right-click a video to tag it.
  Tags live in `categories.json` beside the videos
- Menu-bar app (no Dock icon); everything persists across launches

## Dynamic Island
A live-activity pill at the top of the main display (the one with the menu bar): it
grows out of the notch on a MacBook and attaches to the top edge like a virtual notch
on an external monitor, following you when displays are plugged in or out. Events
spring it open briefly; hover it to expand into stacked cards.

It shows, in priority order:

| Source | How it's tracked | Needs |
|---|---|---|
| **Claude Code** (terminal and the Claude app's Code tab) | Claude Code hooks → `scripts/livewall-claude-hook` | hooks in `~/.claude/settings.json` |
| **ChatGPT & Codex** | the session logs in `~/.codex/sessions` (`task_started` / `task_complete`) | nothing |
| **Claude & ChatGPT app chats** | the apps' Stop button, via the Accessibility API | Accessibility permission |
| **Music** — Spotify and Apple Music, with artwork and ⏮ ⏯ ⏭ | the apps' distributed notifications; controls via AppleScript | Automation permission (asked once) |
| **The wallpaper** — now playing, pause, shuffle, speed | built in | nothing |

**Turning it on and off:** the **Dynamic Island** button in the control panel's
toolbar has a master switch and a switch per source; **Show Dynamic Island** is also
in the menu-bar menu. Automatic pauses (fullscreen apps, sleep) only change its icon,
so it never pops up over a game or presentation.

**Reporting your own activities:** any tool can post to the island with
[`scripts/livewall-activity`](scripts/livewall-activity) (the
`com.livewall.activity` distributed notification):
```bash
scripts/livewall-activity running "Rendering the video" --source "My Tool" --id render
scripts/livewall-activity done "Render complete" --source "My Tool" --id render
```
States are `running`, `attention` and `done`; updates with the same `--id` replace
each other, and `done` clears itself after a few seconds.

**Claude Code hooks** (in `~/.claude/settings.json`, all `async`):

| Hook | Command | Island shows |
|---|---|---|
| `UserPromptSubmit` | `scripts/livewall-claude-hook prompt` | working, with your prompt |
| `Notification` | `scripts/livewall-claude-hook notify` | needs you |
| `PostToolUse` | `scripts/livewall-claude-hook resume` | back to working after you approve |
| `Stop` | `scripts/livewall-claude-hook stop` | done |

## Wallpaper gallery
Free, openly licensed 4K wallpapers to download: **https://live-wallpaper-mac-mauve.vercel.app**

The site lives in [`web/`](web) and is deployed on Vercel (Arthur's projects →
`live-wallpaper-mac`, root directory `web`; pushing to `main` redeploys it). Videos
are stored in the Cloudflare R2 bucket `livewall-media`. The site has a cosmetic
password screen — any password unlocks it; it is not a security boundary.

Only public-domain, CC0, CC BY or own-work content is accepted —
`web/scripts/publish.mjs` refuses any entry without an allowed licence, a credit and
a source. Free stock sites (Pexels, Pixabay, Mixkit…) are excluded: their licences
forbid redistributing clips on wallpaper sites.

To add wallpapers:
1. Cut a clip into `web/content/` with `web/scripts/clip.swift` (MP4/MOV sources) or
   ffmpeg (WebM sources) — a 4K HEVC download, a short 640px preview and a poster.
2. Add the entry to `web/catalog.source.json`.
3. Run `npm run publish-catalog` in `web/` (uploads to R2 via `wrangler`, skipping
   files already there) and commit `web/public/catalog.json`.

The full list is published as [`catalog.json`](https://live-wallpaper-mac-mauve.vercel.app/catalog.json).

## Install

**Requirements:** macOS 26 (Tahoe) or later — the UI uses the Liquid Glass APIs.

```bash
swift build -c release
cp .build/release/LiveWall build/LiveWall.app/Contents/MacOS/LiveWall
codesign --force --deep --sign - build/LiveWall.app
ditto build/LiveWall.app /Applications/LiveWall.app
open /Applications/LiveWall.app
```
The `.app` bundle (`build/LiveWall.app`, not in git) is the release binary plus
`AppIcon.icns` (generated by `make_icon.swift`) and `Contents/Info.plist`, which
includes the Automation usage text for music control. For development,
`./.build/release/LiveWall` runs the app directly (without launch at login).

**Permissions** macOS will ask for:
- **Accessibility** — only for tracking Claude/ChatGPT app chats. The app is ad-hoc
  signed, so macOS forgets this after each reinstall; re-enable it in
  System Settings → Privacy & Security → Accessibility.
- **Automation** (Spotify / Music) — the first time you use the island's music controls.

## Wallpaper library
The library folder is chosen with the folder button in the control panel (it starts
at this repo's `Media/` folder). Drop `.mp4`, `.mov` or `.m4v` files in and they
appear immediately.

Tags are stored in `<library>/categories.json`:
```json
{ "version": 1,
  "tags": ["Cozy", "Nature"],
  "videos": { "autumn-forest-cabin.mp4": ["Cozy", "Nature"] } }
```
Edit it by hand or regenerate it — the app picks up external changes live.

## To do
Where things stand (October 2026). Roadmap features are tracked as issues below.

**Gallery**
- [ ] Install ffmpeg (`brew install ffmpeg`) — the next clips are WebM, which
      `clip.swift` (AVFoundation) can't read
- [ ] Cut and publish the 37 vetted clips in [`web/candidates.json`](web/candidates.json)
      (Wikimedia Commons + Blender open films; licences and clean segments already
      checked). 2.35:1 film shots and a few others need cropping — see each `note`
- [ ] Decide on the 8 CC BY-SA candidates (share-alike) — not yet on the allow-list
- [ ] Delete the 7 old copies in Vercel Blob now the gallery reads from R2
- [ ] Give R2 a custom domain — the `r2.dev` address is rate-limited and meant for development
- [ ] Add a "Browse online" tab to the Mac app that reads `catalog.json`

**Dynamic Island**
- [ ] Confirm chat tracking in the Claude and ChatGPT desktop apps — the Stop-button
      labels it looks for are unverified
- [ ] Sign the app with a Developer ID, so macOS keeps the Accessibility permission
      across updates
- [ ] Pick up music that's already playing when LiveWall launches

**Library**
- [ ] Decide whether to commit the ~72 new videos in `Media/` (and `categories.json`)
      or keep them local; anything over 50 MB must stay in `.gitignore`

## Roadmap
Prioritised from a review of Wallpaper Engine, Lively, Backdrop, Wallper,
Wallux/Wallspace, Phosphene, Aerial and Plash. Each item is tracked as a
[GitHub issue](https://github.com/01AHH/live-wallpaper-mac/issues).

**Done**
- [x] Pause playback when the wallpaper is hidden (fullscreen apps, covered screens, displays asleep)
- [x] Per-video playback speed
- [x] Dynamic Island with music, AI activities and wallpaper controls
- [x] Launch at login ([#14](https://github.com/01AHH/live-wallpaper-mac/issues/14))

**Must have** — table stakes every serious competitor has
- [ ] Pause or degrade playback on battery and Low Power Mode ([#1](https://github.com/01AHH/live-wallpaper-mac/issues/1))
- [ ] Thermal-state awareness ([#2](https://github.com/01AHH/live-wallpaper-mac/issues/2))
- [ ] Per-screen players and per-screen pause ([#3](https://github.com/01AHH/live-wallpaper-mac/issues/3))
- [ ] Playlists and rotation ([#4](https://github.com/01AHH/live-wallpaper-mac/issues/4))
- [ ] Menu-bar quick controls ([#5](https://github.com/01AHH/live-wallpaper-mac/issues/5))
- [ ] Sync a still frame to the system wallpaper ([#6](https://github.com/01AHH/live-wallpaper-mac/issues/6))

**Should have** — differentiators
- [ ] Live video on the lock and login screens (experimental) ([#7](https://github.com/01AHH/live-wallpaper-mac/issues/7))
- [ ] Per-app rules (including camera in use) ([#8](https://github.com/01AHH/live-wallpaper-mac/issues/8))
- [ ] Lower-resolution variants on battery ([#9](https://github.com/01AHH/live-wallpaper-mac/issues/9))
- [ ] Shortcuts actions and global hotkeys ([#10](https://github.com/01AHH/live-wallpaper-mac/issues/10))
- [ ] Schedules: time of day, sunrise/sunset, light/dark mode ([#11](https://github.com/01AHH/live-wallpaper-mac/issues/11))
- [ ] Import tool: convert to HEVC, trim, smooth the loop seam ([#12](https://github.com/01AHH/live-wallpaper-mac/issues/12))
- [ ] Smooth motion for slowed-down videos ([#13](https://github.com/01AHH/live-wallpaper-mac/issues/13))

**Could have**
- [ ] Interactive web/HTML scenes ([#15](https://github.com/01AHH/live-wallpaper-mac/issues/15))
- [ ] Nice-to-haves from competitor research ([#16](https://github.com/01AHH/live-wallpaper-mac/issues/16))
