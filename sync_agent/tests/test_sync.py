"""Sync agent tests with in-memory stand-ins for Supabase and R2."""

import queue
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import vibe_sync as vs  # noqa: E402
from analyze import analyze_file, mood_scores_for  # noqa: E402

SR = 22050


def _calm(path: Path):
    t = np.arange(SR * 30) / SR
    y = 0.05 * sum(np.sin(2 * np.pi * f * t) for f in (261.6, 329.6, 392.0)) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.1 * t))
    sf.write(path, y, SR)


def _party(path: Path):
    t = np.arange(SR * 30) / SR
    y = np.zeros_like(t)
    period = 60 / 128
    rng = np.random.default_rng(0)
    for k in np.arange(0, 29, period):
        i, n = int(k * SR), int(0.12 * SR)
        y[i:i + n] += 0.9 * np.sin(2 * np.pi * 60 * np.arange(n) / SR) * np.exp(-np.arange(n) / (0.03 * SR))
        j, m = int((k + period / 2) * SR), int(0.05 * SR)
        y[j:j + m] += 0.3 * rng.standard_normal(m) * np.exp(-np.arange(m) / (0.01 * SR))
    y += 0.25 * np.sign(np.sin(2 * np.pi * 110 * t))
    sf.write(path, np.clip(y, -1, 1), SR)


@pytest.fixture
def library(tmp_path):
    music = tmp_path / "music"
    (music / "sub").mkdir(parents=True)
    _calm(music / "calm.wav")
    _party(music / "sub" / "party.wav")
    return music


class FakeDB:
    def __init__(self):
        self.rows = {}

    def find(self, h):
        r = self.rows.get(h)
        return {"id": h, "deleted": r["deleted"], "source_path": r["source_path"]} if r else None

    def upsert(self, row):
        self.rows.setdefault(row["content_hash"], {}).update(row)

    def update(self, h, fields):
        self.rows[h].update(fields)


class FakeR2:
    def __init__(self):
        self.objects = {}

    def exists(self, key):
        return key in self.objects

    def upload_file(self, path, key, content_type):
        self.objects[key] = content_type

    def upload_bytes(self, data, key, content_type):
        self.objects[key] = content_type


def make_agent(music: Path, tmp_path: Path):
    cfg = type("Cfg", (), {"music_dir": music.resolve(), "analyze": True})()
    agent = vs.Agent.__new__(vs.Agent)
    agent.cfg = cfg
    agent.state = vs.State(tmp_path / "state.db")
    agent.db = FakeDB()
    agent.r2 = FakeR2()
    agent.work = queue.Queue()
    return agent


def test_moods_are_told_apart(library):
    calm = analyze_file(str(library / "calm.wav"), 30)
    party = analyze_file(str(library / "sub" / "party.wav"), 30)
    assert calm.mood == "calm"
    assert party.mood in ("party", "energetic")
    assert party.energy > calm.energy


def test_keywords_nudge_mood():
    neutral = mood_scores_for(0.5, 0.5, 0.5, 0.5, "")
    lofi = mood_scores_for(0.5, 0.5, 0.5, 0.5, "Lofi Study Beats")
    assert lofi["focus"] > neutral["focus"]


def test_scan_uploads_once_and_tracks_removals(library, tmp_path):
    agent = make_agent(library, tmp_path)
    agent.full_scan()
    assert len(agent.db.rows) == 2
    assert len([k for k in agent.r2.objects if k.startswith("audio/")]) == 2

    uploads_before = dict(agent.r2.objects)
    agent.full_scan()
    assert agent.r2.objects == uploads_before  # nothing re-uploaded

    # A copy of the same song under another name is not a new song,
    # and removing one copy keeps it visible.
    shutil.copy(library / "calm.wav", library / "calm copy.wav")
    agent.full_scan()
    assert len(agent.db.rows) == 2
    (library / "calm.wav").unlink()
    agent.full_scan()
    assert not any(r["deleted"] for r in agent.db.rows.values())

    # Removing the last copy hides it in the app.
    (library / "calm copy.wav").unlink()
    agent.full_scan()
    hidden = [r["title"] for r in agent.db.rows.values() if r["deleted"]]
    assert hidden == ["calm"]

    # Putting it back restores it.
    _calm(library / "calm.wav")
    agent.full_scan()
    assert not any(r["deleted"] for r in agent.db.rows.values())
