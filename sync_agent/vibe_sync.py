"""Vibe sync agent: keeps your laptop music folder in sync with the app.

Run it and leave it running (or set it to start with your laptop). It
1. scans your music folder,
2. analyses each new song's mood,
3. uploads the audio and cover art to Cloudflare R2,
4. adds the song to the Supabase library, where the app picks it up live.

Removing a file from the folder hides it in the app.

Usage:
    python vibe_sync.py              # scan, then keep watching for changes
    python vibe_sync.py --once       # scan once and exit
    python vibe_sync.py --reanalyze  # redo mood analysis for every song
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import mimetypes
import os
import queue
import sqlite3
import sys
import threading
import time
import tomllib
from pathlib import Path

import requests

from analyze import Analysis, analyze_file, mood_scores_for

AUDIO_EXTS = {".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wav"}
CONTENT_TYPES = {
    ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac", ".flac": "audio/flac",
    ".ogg": "audio/ogg", ".opus": "audio/ogg", ".wav": "audio/wav",
}
RESCAN_EVERY_S = 10 * 60
STABLE_WAIT_S = 3

log = logging.getLogger("vibe-sync")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
class Config:
    def __init__(self, path: Path):
        if not path.exists():
            sys.exit(f"Config file not found: {path}\nCopy config.example.toml to config.toml and fill it in.")
        data = tomllib.loads(path.read_text(encoding="utf-8"))
        try:
            self.music_dir = Path(os.path.expanduser(data["music_folder"])).resolve()
            self.supabase_url = data["supabase"]["url"].rstrip("/")
            self.supabase_key = data["supabase"]["secret_key"]
            r2 = data["r2"]
            self.r2_account_id = r2["account_id"]
            self.r2_access_key = r2["access_key_id"]
            self.r2_secret = r2["secret_access_key"]
            self.r2_bucket = r2["bucket"]
        except KeyError as e:
            sys.exit(f"config.toml is missing {e}. Compare it with config.example.toml.")
        self.analyze = data.get("analyze_mood", True)
        if not self.music_dir.is_dir():
            sys.exit(f"Music folder does not exist: {self.music_dir}")


# ---------------------------------------------------------------------------
# Local memory of what has been uploaded, so restarts are instant.
# ---------------------------------------------------------------------------
class State:
    def __init__(self, db_path: Path):
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self.lock = threading.Lock()
        self.db.execute(
            "create table if not exists files (path text primary key, size int, mtime real, hash text)"
        )
        self.db.commit()

    def get(self, rel: str):
        with self.lock:
            return self.db.execute("select size, mtime, hash from files where path=?", (rel,)).fetchone()

    def put(self, rel: str, size: int, mtime: float, digest: str):
        with self.lock:
            self.db.execute("insert or replace into files values (?,?,?,?)", (rel, size, mtime, digest))
            self.db.commit()

    def remove(self, rel: str) -> str | None:
        with self.lock:
            row = self.db.execute("select hash from files where path=?", (rel,)).fetchone()
            self.db.execute("delete from files where path=?", (rel,))
            self.db.commit()
            return row[0] if row else None

    def paths(self) -> list[str]:
        with self.lock:
            return [r[0] for r in self.db.execute("select path from files")]

    def hash_in_use(self, digest: str) -> bool:
        with self.lock:
            return self.db.execute("select 1 from files where hash=? limit 1", (digest,)).fetchone() is not None


# ---------------------------------------------------------------------------
# Remote services
# ---------------------------------------------------------------------------
class Supabase:
    def __init__(self, cfg: Config):
        self.base = f"{cfg.supabase_url}/rest/v1"
        self.s = requests.Session()
        self.s.headers["apikey"] = cfg.supabase_key
        # Legacy service_role keys are JWTs and also go in Authorization.
        if not cfg.supabase_key.startswith("sb_"):
            self.s.headers["Authorization"] = f"Bearer {cfg.supabase_key}"
        self.s.headers["Content-Type"] = "application/json"

    def _check(self, r: requests.Response):
        if r.status_code >= 400:
            raise RuntimeError(f"Supabase {r.status_code}: {r.text[:300]}")
        return r

    def find(self, digest: str) -> dict | None:
        r = self._check(self.s.get(f"{self.base}/songs", params={"content_hash": f"eq.{digest}", "select": "id,deleted,source_path"}))
        rows = r.json()
        return rows[0] if rows else None

    def upsert(self, row: dict):
        self._check(self.s.post(
            f"{self.base}/songs", params={"on_conflict": "content_hash"}, json=row,
            headers={"Prefer": "resolution=merge-duplicates,return=minimal"},
        ))

    def update(self, digest: str, fields: dict):
        self._check(self.s.patch(f"{self.base}/songs", params={"content_hash": f"eq.{digest}"}, json=fields))


class R2:
    def __init__(self, cfg: Config):
        import boto3
        from botocore.config import Config as BotoConfig

        self.bucket = cfg.r2_bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=f"https://{cfg.r2_account_id}.r2.cloudflarestorage.com",
            aws_access_key_id=cfg.r2_access_key,
            aws_secret_access_key=cfg.r2_secret,
            region_name="auto",
            config=BotoConfig(retries={"max_attempts": 5, "mode": "standard"}),
        )

    def exists(self, key: str) -> bool:
        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except Exception:
            return False

    def upload_file(self, path: Path, key: str, content_type: str):
        self.client.upload_file(str(path), self.bucket, key, ExtraArgs={"ContentType": content_type})

    def upload_bytes(self, data: bytes, key: str, content_type: str):
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type)


# ---------------------------------------------------------------------------
# Reading the file
# ---------------------------------------------------------------------------
def sha1_of(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_tags(path: Path) -> dict:
    import mutagen

    tags = {"title": path.stem, "artist": "Unknown artist", "album": None, "genre": None, "year": None, "duration_ms": 0}
    try:
        easy = mutagen.File(path, easy=True)
    except Exception:
        easy = None
    if easy is None:
        return tags
    if easy.info is not None and getattr(easy.info, "length", None):
        tags["duration_ms"] = int(easy.info.length * 1000)

    def first(key):
        try:
            v = easy.get(key)
        except Exception:
            return None
        return str(v[0]).strip() if v else None

    tags["title"] = first("title") or path.stem
    tags["artist"] = first("artist") or first("albumartist") or "Unknown artist"
    tags["album"] = first("album")
    tags["genre"] = first("genre")
    date = first("date") or first("year")
    if date and date[:4].isdigit():
        tags["year"] = int(date[:4])
    return tags


def read_cover(path: Path) -> tuple[bytes, str] | None:
    import mutagen

    try:
        f = mutagen.File(path)
    except Exception:
        return None
    if f is None:
        return None
    # FLAC
    pictures = getattr(f, "pictures", None)
    if pictures:
        return pictures[0].data, pictures[0].mime or "image/jpeg"
    tags = f.tags
    if tags is None:
        return None
    # MP3 (ID3 APIC frames)
    for key in list(tags.keys()):
        if str(key).startswith("APIC"):
            frame = tags[key]
            return frame.data, frame.mime or "image/jpeg"
    # MP4/M4A
    if "covr" in tags and tags["covr"]:
        data = bytes(tags["covr"][0])
        return data, "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
    # Ogg/Opus
    if "metadata_block_picture" in tags:
        import base64
        from mutagen.flac import Picture

        pic = Picture(base64.b64decode(tags["metadata_block_picture"][0]))
        return pic.data, pic.mime or "image/jpeg"
    return None


def analysis_row(a: Analysis) -> dict:
    return {
        "bpm": a.bpm, "energy": a.energy, "valence": a.valence, "danceability": a.danceability,
        "acousticness": a.acousticness, "features": a.features, "mood": a.mood, "mood_scores": a.mood_scores,
    }


# ---------------------------------------------------------------------------
# The agent
# ---------------------------------------------------------------------------
class Agent:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.state = State(Path(__file__).with_name(".vibe_sync.db"))
        self.db = Supabase(cfg)
        self.r2 = R2(cfg)
        self.work: queue.Queue[tuple[str, str]] = queue.Queue()

    def rel(self, path: Path) -> str:
        return path.relative_to(self.cfg.music_dir).as_posix()

    def is_audio(self, path: Path) -> bool:
        return path.suffix.lower() in AUDIO_EXTS and not path.name.startswith(".")

    # -- one file ----------------------------------------------------------
    def sync_file(self, path: Path, force_analyze: bool = False):
        if not path.exists() or not self.is_audio(path):
            return
        rel = self.rel(path)
        st = path.stat()
        known = self.state.get(rel)
        if known and known[0] == st.st_size and abs(known[1] - st.st_mtime) < 1 and not force_analyze:
            return

        digest = sha1_of(path)
        if known and known[2] != digest:
            self.state.remove(rel)
            self._hide_if_unused(known[2])

        remote = self.db.find(digest)
        if remote and not force_analyze:
            fields = {"source_path": rel}
            if remote["deleted"]:
                fields["deleted"] = False
                log.info("Restored  %s", rel)
            self.db.update(digest, fields)
            self.state.put(rel, st.st_size, st.st_mtime, digest)
            return

        tags = read_tags(path)
        tag_text = " ".join(str(v) for v in (tags["genre"], tags["title"], tags["album"], rel) if v)
        log.info("Analysing %s", rel)
        row = dict(tags)
        try:
            if not self.cfg.analyze:
                raise RuntimeError("analysis turned off")
            row.update(analysis_row(analyze_file(str(path), tags["duration_ms"] / 1000 or None, tag_text)))
        except Exception as e:
            log.warning("  mood analysis skipped (%s); using tags only", e)
            scores = mood_scores_for(0.5, 0.5, 0.5, 0.5, tag_text)
            row.update({"mood": max(scores, key=scores.get), "mood_scores": scores})

        ext = path.suffix.lower()
        audio_key = f"audio/{digest}{ext}"
        if not self.r2.exists(audio_key):
            log.info("Uploading %s (%.1f MB)", rel, st.st_size / 1e6)
            self.r2.upload_file(path, audio_key, CONTENT_TYPES.get(ext) or mimetypes.guess_type(path.name)[0] or "application/octet-stream")

        cover = read_cover(path)
        if cover:
            data, mime = cover
            cover_key = f"covers/{digest}{'.png' if 'png' in mime else '.jpg'}"
            if not self.r2.exists(cover_key):
                self.r2.upload_bytes(data, cover_key, mime)
            row["cover_key"] = cover_key

        row.update({
            "content_hash": digest, "storage_key": audio_key, "file_ext": ext.lstrip("."),
            "file_size": st.st_size, "source_path": rel, "deleted": False,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        self.db.upsert(row)
        self.state.put(rel, st.st_size, st.st_mtime, digest)
        log.info("Added     %s - %s  [%s]", row["artist"], row["title"], row.get("mood"))

    def remove_path(self, rel: str):
        digest = self.state.remove(rel)
        if digest:
            self._hide_if_unused(digest)
            log.info("Removed   %s", rel)

    def _hide_if_unused(self, digest: str):
        # The same song might also exist under another file name.
        if not self.state.hash_in_use(digest):
            self.db.update(digest, {"deleted": True})

    # -- whole folder ------------------------------------------------------
    def full_scan(self, force_analyze: bool = False):
        seen = set()
        files = sorted(p for p in self.cfg.music_dir.rglob("*") if p.is_file() and self.is_audio(p))
        log.info("Scanning %d audio files in %s", len(files), self.cfg.music_dir)
        for p in files:
            seen.add(self.rel(p))
            self._safe(self.sync_file, p, force_analyze)
        for rel in self.state.paths():
            if rel not in seen:
                self._safe(self.remove_path, rel)
        log.info("Scan finished. Library is up to date.")

    def _safe(self, fn, *args):
        try:
            fn(*args)
        except Exception as e:
            log.error("Failed on %s: %s", args[0], e)

    # -- watching ----------------------------------------------------------
    def watch(self):
        from watchdog.events import FileSystemEventHandler
        from watchdog.observers import Observer

        agent = self

        class Handler(FileSystemEventHandler):
            def on_created(self, e):
                if not e.is_directory:
                    agent.work.put(("sync", e.src_path))

            def on_modified(self, e):
                if not e.is_directory:
                    agent.work.put(("sync", e.src_path))

            def on_moved(self, e):
                agent.work.put(("gone", e.src_path))
                agent.work.put(("sync", e.dest_path))

            def on_deleted(self, e):
                agent.work.put(("gone", e.src_path))

        observer = Observer()
        observer.schedule(Handler(), str(self.cfg.music_dir), recursive=True)
        observer.start()
        log.info("Watching %s for new songs. Press Ctrl+C to stop.", self.cfg.music_dir)

        pending: dict[str, float] = {}
        last_scan = time.time()
        try:
            while True:
                try:
                    kind, raw = self.work.get(timeout=1)
                    path = Path(raw)
                    if kind == "gone":
                        if path.suffix.lower() in AUDIO_EXTS:
                            self._safe(self.remove_path, self.rel(path))
                        else:  # a whole folder was removed or renamed
                            prefix = self.rel(path) + "/"
                            for rel in self.state.paths():
                                if rel.startswith(prefix):
                                    self._safe(self.remove_path, rel)
                    elif path.is_dir():
                        for p in path.rglob("*"):
                            if p.is_file() and self.is_audio(p):
                                pending[str(p)] = time.time()
                    elif self.is_audio(path):
                        pending[str(path)] = time.time()
                except queue.Empty:
                    pass

                # Wait until a file stops changing (still being copied) before syncing it.
                now = time.time()
                for raw, t in list(pending.items()):
                    if now - t >= STABLE_WAIT_S:
                        del pending[raw]
                        self._safe(self.sync_file, Path(raw))

                if now - last_scan > RESCAN_EVERY_S:
                    self.full_scan()
                    last_scan = time.time()
        except KeyboardInterrupt:
            pass
        finally:
            observer.stop()
            observer.join()


def main():
    ap = argparse.ArgumentParser(description="Sync a music folder to the Vibe app.")
    ap.add_argument("--config", default=str(Path(__file__).with_name("config.toml")))
    ap.add_argument("--once", action="store_true", help="scan once and exit")
    ap.add_argument("--reanalyze", action="store_true", help="redo mood analysis for every song")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s  %(message)s", datefmt="%H:%M:%S",
    )
    logging.getLogger("botocore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)

    agent = Agent(Config(Path(args.config)))
    agent.full_scan(force_analyze=args.reanalyze)
    if not args.once and not args.reanalyze:
        agent.watch()


if __name__ == "__main__":
    main()
