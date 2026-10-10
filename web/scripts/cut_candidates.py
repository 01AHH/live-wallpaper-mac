"""Cut the vetted clips in web/candidates.json into gallery files with ffmpeg.

    python3 web/scripts/cut_candidates.py [id ...]     # all candidates by default

For each candidate it writes web/content/<id>.mp4 (HEVC, up to 4K, 16:9, no
audio), <id>-preview.mp4 (8 s, small H.264) and <id>.jpg (poster), then adds
or updates the entry in web/catalog.source.json. The sources are WebM (VP9 or
AV1), which AVFoundation can't read, so this uses ffmpeg rather than clip.swift.
"""
import json, pathlib, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

WEB = pathlib.Path(__file__).resolve().parents[1]
CONTENT = WEB / "content"
# Whole source files are cached here. Wikimedia throttles ffmpeg's many range
# requests (HTTP 429), so each file is fetched once, politely, with curl.
CACHE = pathlib.Path.home() / "Library" / "Caches" / "livewall-candidates"
USER_AGENT = "LiveWallGallery/1.0 (https://livewallpapermac.vercel.app; clip preparation)"

# Trims applied before the 16:9 crop, from the candidates' notes:
# (left, top, right, bottom) as fractions of the frame.
TRIM = {
    "hof-cloud-parade": (0, 0.05, 0, 0),       # small dark object at the top edge
    "pine-forest-floor": (0, 0.03, 0, 0.03),   # black bars
    "bangkok-dusk": (0.05, 0, 0, 0),           # dark window edge on the left
    "earth-day-orbit": (0, 0.13, 0, 0.13),     # letterboxed ~2.4:1
}


def probe(url):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "json", url],
                         capture_output=True, text=True, timeout=120, check=True).stdout
    s = json.loads(out)["streams"][0]
    return s["width"], s["height"]


def fetch(c):
    """Download a candidate's source once; returns the local path."""
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{c['id']}.webm"
    if path.exists() and path.stat().st_size > 0:
        return path
    part = path.with_suffix(".part")
    for attempt in range(6):
        result = subprocess.run(["curl", "-sSfL", "-A", USER_AGENT, "-C", "-", "-o", str(part), c["file"]],
                                capture_output=True, text=True)
        if result.returncode == 0:
            part.rename(path)
            return path
        time.sleep(20 * (attempt + 1))   # back off on 429s and dropped connections
    raise RuntimeError(f"download failed: {result.stderr.strip()}")


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args],
                   check=True, timeout=1800, capture_output=True)


def cut(c):
    cid = c["id"]
    try:
        src = str(c["local"])
        w, h = probe(src)
        l, t, r, b = TRIM.get(cid, (0, 0, 0, 0))
        tw, th = w * (1 - l - r), h * (1 - t - b)
        # Centre-crop to 16:9, then cap at 4K.
        if tw / th > 16 / 9:
            cw, ch = th * 16 / 9, th
        else:
            cw, ch = tw, tw * 9 / 16
        ox, oy = w * l + (tw - cw) / 2, h * t + (th - ch) / 2
        oh = min(2160, int(ch)) // 2 * 2
        ow = round(oh * 16 / 9) // 2 * 2
        vf = f"crop={int(cw)}:{int(ch)}:{int(ox)}:{int(oy)},scale={ow}:{oh}:flags=lanczos,format=yuv420p"

        # Pull the stretch once, losslessly enough, then encode from the local copy.
        raw = CONTENT / f".{cid}-raw.mkv"
        ffmpeg("-ss", str(c["start"]), "-t", str(c["duration"]), "-i", src, "-an",
               "-c:v", "copy", str(raw))
        full = CONTENT / f"{cid}.mp4"
        ffmpeg("-i", str(raw), "-an", "-vf", vf, "-c:v", "hevc_videotoolbox", "-b:v", "28M" if oh >= 2160 else "14M",
               "-tag:v", "hvc1", "-movflags", "+faststart", str(full))
        ffmpeg("-i", str(full), "-t", "8", "-an", "-vf", "scale=640:-2", "-c:v", "h264_videotoolbox",
               "-b:v", "1500k", "-movflags", "+faststart", str(CONTENT / f"{cid}-preview.mp4"))
        ffmpeg("-ss", str(min(2, c["duration"] / 2)), "-i", str(full), "-frames:v", "1",
               "-vf", "scale=1280:-2", "-q:v", "3", str(CONTENT / f"{cid}.jpg"))
        raw.unlink(missing_ok=True)
        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                    "csv=p=0", str(full)], capture_output=True, text=True).stdout.strip())
        return cid, {"resolution": f"{ow}x{oh}", "duration": round(dur)}, None
    except Exception as e:  # keep going; report at the end
        msg = getattr(e, "stderr", b"") or str(e)
        return cid, None, (msg.decode(errors="ignore") if isinstance(msg, bytes) else str(msg)).strip()[-300:]


def main():
    candidates = json.loads((WEB / "candidates.json").read_text())["candidates"]
    if sys.argv[1:]:
        candidates = [c for c in candidates if c["id"] in sys.argv[1:]]
    CONTENT.mkdir(exist_ok=True)
    # Downloads one at a time (polite to Wikimedia); encodes three at a time.
    results, jobs = [], []
    with ThreadPoolExecutor(max_workers=3) as pool:
        for c in candidates:
            try:
                c["local"] = fetch(c)
                print(f"↓ {c['id']}", flush=True)
                jobs.append(pool.submit(cut, c))
            except Exception as e:
                jobs.append(None)
                results.append((c["id"], None, str(e)))
        done = {j.result()[0]: j.result() for j in jobs if j}
    failed_dl = {r[0]: r for r in results}
    results = [done.get(c["id"]) or failed_dl[c["id"]] for c in candidates]

    source_path = WEB / "catalog.source.json"
    source = json.loads(source_path.read_text())
    by_id = {w["id"]: w for w in source["wallpapers"]}
    failed = []
    for c, (cid, info, err) in zip(candidates, results):
        if err:
            failed.append((cid, err))
            print(f"✗ {cid}: {err}")
            continue
        entry = {
            "id": cid, "title": c["title"], "description": c["description"], "tags": c["tags"],
            "credit": c["credit"], "source": c["source"], "sourceStart": c["start"],
            "licence": c["licence"], "resolution": info["resolution"], "codec": "HEVC",
            "duration": info["duration"],
        }
        if cid in by_id:
            by_id[cid].update(entry)
        else:
            source["wallpapers"].append(entry)
            by_id[cid] = entry
        print(f"✓ {cid}: {info['resolution']}, {info['duration']} s")
    source_path.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    print(f"{len(candidates) - len(failed)} cut, {len(failed)} failed")


main()
