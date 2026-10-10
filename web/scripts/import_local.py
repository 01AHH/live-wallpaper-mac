#!/usr/bin/env python3
"""Add finished wallpapers from a LiveWall library to the gallery as-is.

Unlike clip.swift (which cuts a segment out of longer footage), this keeps the
whole loop: the video is copied without audio (no re-encode), and a short
640px H.264 preview and a poster are made with ffmpeg. Each wallpaper gets an
entry in catalog.source.json using its tags from the library's categories.json.

Entries are marked `"unverified": true` with licence "Unverified" — the
gallery shows them with a "Licence unverified" flag, and publish.mjs only
accepts that licence on entries carrying the flag.

    python3 scripts/import_local.py --library ../Media --tag Japan
    python3 scripts/import_local.py --library ../Media --name 'lo-?fi' --label Lofi
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

WEB = Path(__file__).resolve().parent.parent
CONTENT = WEB / "content"
SOURCE = WEB / "catalog.source.json"
NOISE = {"live", "wallpaper", "4k", "download", "lively", "animated"}


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=codec_name,width,height:format=duration",
         "-of", "json", str(path)], check=True, capture_output=True, text=True).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    return stream, float(data["format"]["duration"])


def title_for(stem):
    words = [w for w in re.split(r"[-_ ]+", stem) if w and w.lower() not in NOISE]
    return " ".join(w if w.isupper() else w.capitalize() for w in words)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--tag", help="import every video with this library tag")
    parser.add_argument("--name", help="import every video whose file name matches this regex")
    parser.add_argument("--label", help="gallery tag to add to every imported wallpaper")
    args = parser.parse_args()
    if not (args.tag or args.name):
        parser.error("give --tag and/or --name")

    tags = json.loads((args.library / "categories.json").read_text())["videos"]
    videos = sorted(p.name for p in args.library.iterdir() if p.suffix.lower() in {".mp4", ".mov", ".m4v"})
    pattern = re.compile(args.name, re.I) if args.name else None
    files = [n for n in videos
             if (args.tag and args.tag in tags.get(n, [])) or (pattern and pattern.search(n))]
    label = args.label or args.tag
    catalog = json.loads(SOURCE.read_text())
    known = {w["id"] for w in catalog["wallpapers"]}
    CONTENT.mkdir(exist_ok=True)

    for name in files:
        src = args.library / name
        if not src.exists():
            print(f"  skip {name} (missing)")
            continue
        wid = re.sub(r"[^a-z0-9-]+", "-", Path(name).stem.lower()).strip("-")
        stream, duration = probe(src)

        # Whole loop, audio dropped, no re-encode; faststart so it streams.
        run("ffmpeg", "-y", "-i", str(src), "-map", "0:v:0", "-c", "copy", "-an",
            "-movflags", "+faststart", str(CONTENT / f"{wid}.mp4"))
        # Short, small H.264 preview for hover (plays in every browser).
        run("ffmpeg", "-y", "-t", "8", "-i", str(src), "-an", "-vf", "scale=640:-2",
            "-c:v", "h264_videotoolbox", "-b:v", "1500k", "-movflags", "+faststart",
            str(CONTENT / f"{wid}-preview.mp4"))
        run("ffmpeg", "-y", "-ss", str(min(2.0, duration / 2)), "-i", str(src),
            "-frames:v", "1", "-vf", "scale=1280:-2", "-q:v", "3", str(CONTENT / f"{wid}.jpg"))

        if wid not in known:
            catalog["wallpapers"].append({
                "id": wid,
                "title": title_for(Path(name).stem),
                "description": f"{title_for(Path(name).stem)} — a {label} live wallpaper.",
                "tags": sorted(set(tags.get(name, [])) | ({label} if label else set())),
                "credit": "Source unknown",
                "source": None,
                "licence": {"name": "Unverified", "url": None},
                "unverified": True,
                "resolution": f"{stream['width']}x{stream['height']}",
                "codec": "HEVC" if stream["codec_name"] == "hevc" else "H.264",
                "duration": round(duration),
            })
            known.add(wid)
        print(f"  {wid}")

    SOURCE.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n")
    print(f"Imported {len(files)} '{label}' wallpapers into catalog.source.json")


if __name__ == "__main__":
    main()
