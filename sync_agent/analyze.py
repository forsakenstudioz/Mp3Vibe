"""Audio analysis: turns a song into numbers the app can reason about.

For each file we listen to about a minute from the middle of the track and
measure tempo, loudness, brightness, how percussive it is, whether it sounds
major or minor, and a timbre fingerprint (MFCCs). From those we estimate
energy, valence (happy vs sad), danceability and acousticness, and score each
mood. Song tags (genre, title) nudge the scores, e.g. "lofi" leans focus/calm,
"dance" leans party, "bhajan" leans calm.
"""

from __future__ import annotations

import math
import warnings
from dataclasses import dataclass, field

import numpy as np

MOODS = ("energetic", "party", "calm", "romantic", "sad", "focus")

# Prototype points in (energy, valence, danceability, acousticness).
MOOD_PROTOTYPES = {
    "energetic": (0.85, 0.60, 0.65, 0.20),
    "party":     (0.80, 0.80, 0.85, 0.15),
    "calm":      (0.25, 0.55, 0.30, 0.75),
    "romantic":  (0.40, 0.65, 0.50, 0.55),
    "sad":       (0.30, 0.20, 0.30, 0.55),
    "focus":     (0.35, 0.45, 0.40, 0.60),
}

# Words in genre/title/album that hint at a mood. Covers English and common
# Indian music terms since the library may mix both.
KEYWORD_HINTS = {
    "party": ("party", "dance", "edm", "club", "remix", "house", "disco", "dj", "bhangra", "kuthu", "dappankuthu", "item"),
    "energetic": ("rock", "metal", "punk", "hip hop", "hip-hop", "rap", "trap", "gaana", "gana", "mass", "workout", "drum and bass", "dubstep", "folk dance"),
    "calm": ("ambient", "chill", "acoustic", "classical", "piano", "sleep", "relax", "bhajan", "devotional", "carnatic", "meditation", "instrumental", "nature"),
    "romantic": ("love", "romantic", "romance", "kadhal", "pyaar", "ishq", "melody", "r&b", "rnb", "soul", "ghazal"),
    "sad": ("sad", "heartbreak", "breakup", "lonely", "pain", "soga", "dard", "blues", "emo"),
    "focus": ("lofi", "lo-fi", "study", "focus", "jazz", "post-rock", "soundtrack", "score", "instrumental"),
}

ANALYSIS_SR = 22050
ANALYSIS_SECONDS = 60.0


@dataclass
class Analysis:
    bpm: float
    energy: float
    valence: float
    danceability: float
    acousticness: float
    features: list[float]
    mood: str
    mood_scores: dict[str, float] = field(default_factory=dict)


def _squash(x: float, mid: float, spread: float) -> float:
    """Map a raw measurement onto 0..1 with a soft S-curve centred on `mid`."""
    return float(1.0 / (1.0 + math.exp(-(x - mid) / spread)))


def _key_mode(chroma_mean: np.ndarray) -> float:
    """Krumhansl key profiles: returns +1 for clearly major, -1 for clearly minor."""
    major = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    minor = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    if not np.any(chroma_mean):
        return 0.0
    best_major = max(np.corrcoef(chroma_mean, np.roll(major, k))[0, 1] for k in range(12))
    best_minor = max(np.corrcoef(chroma_mean, np.roll(minor, k))[0, 1] for k in range(12))
    if np.isnan(best_major) or np.isnan(best_minor):
        return 0.0
    return float(np.clip((best_major - best_minor) * 5.0, -1.0, 1.0))


def mood_scores_for(energy: float, valence: float, dance: float, acoustic: float, text: str = "") -> dict[str, float]:
    # Acousticness is the least reliable estimate, so it counts for less.
    weights = np.array([1.2, 1.0, 1.0, 0.6])
    point = np.array([energy, valence, dance, acoustic])
    scores = {}
    for mood, proto in MOOD_PROTOTYPES.items():
        dist = float(np.linalg.norm((point - np.array(proto)) * weights))
        scores[mood] = math.exp(-(dist ** 2) / 0.08)
    text = text.lower()
    for mood, words in KEYWORD_HINTS.items():
        if any(w in text for w in words):
            scores[mood] = scores[mood] * 0.5 + 0.6
    top = max(scores.values()) or 1.0
    return {m: round(s / top, 3) for m, s in scores.items()}


def analyze_file(path: str, duration_s: float | None = None, tag_text: str = "") -> Analysis:
    import librosa  # imported lazily: it is slow to load

    offset = 0.0
    if duration_s and duration_s > ANALYSIS_SECONDS + 20:
        offset = max(0.0, min(duration_s * 0.3, duration_s - ANALYSIS_SECONDS - 5))

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        y, sr = librosa.load(path, sr=ANALYSIS_SR, mono=True, offset=offset, duration=ANALYSIS_SECONDS)
    if y.size < sr * 3:
        raise ValueError("audio too short to analyse")

    y_harm, y_perc = librosa.effects.hpss(y)
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    tempo, beats = librosa.beat.beat_track(onset_envelope=onset_env, sr=sr)
    bpm = float(np.atleast_1d(tempo)[0])

    rms = float(np.mean(librosa.feature.rms(y=y)))
    centroid = float(np.mean(librosa.feature.spectral_centroid(y=y, sr=sr)))
    flatness = float(np.mean(librosa.feature.spectral_flatness(y=y)))
    zcr = float(np.mean(librosa.feature.zero_crossing_rate(y)))
    onset_mean = float(np.mean(onset_env))
    perc_ratio = float(np.sum(y_perc ** 2) / (np.sum(y_harm ** 2) + np.sum(y_perc ** 2) + 1e-9))
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=sr)
    mode = _key_mode(chroma.mean(axis=1))
    mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)

    # Beat regularity: strong, evenly spaced beats feel danceable.
    if len(beats) > 4:
        intervals = np.diff(librosa.frames_to_time(beats, sr=sr))
        regularity = float(1.0 - min(1.0, np.std(intervals) / (np.mean(intervals) + 1e-9) * 4))
        beat_strength = float(np.mean(onset_env[beats]) / (onset_mean + 1e-9))
    else:
        regularity, beat_strength = 0.0, 1.0

    loud = _squash(rms, 0.12, 0.04)
    bright = _squash(centroid, 2200, 500)
    punch = _squash(onset_mean, 1.4, 0.4)
    tempo_feel = _squash(bpm, 110, 18)

    energy = float(np.clip(0.40 * loud + 0.25 * punch + 0.20 * bright + 0.15 * tempo_feel, 0, 1))
    danceability = float(np.clip(
        0.40 * regularity + 0.25 * _squash(beat_strength, 1.6, 0.3)
        + 0.20 * (1 - abs(bpm - 118) / 60) + 0.15 * perc_ratio * 2, 0, 1))
    acousticness = float(np.clip(1 - (0.35 * perc_ratio * 2 + 0.20 * _squash(flatness, 0.02, 0.01) + 0.20 * bright + 0.25 * loud), 0, 1))
    valence = float(np.clip(0.45 * (mode + 1) / 2 + 0.25 * tempo_feel + 0.20 * bright + 0.10 * danceability, 0, 1))

    scores = mood_scores_for(energy, valence, danceability, acousticness, tag_text)
    mood = max(scores, key=scores.get)

    # Vector for "sounds like" matching. The app standardises each column
    # across the whole library, so raw scales are fine here.
    features = [energy, valence, danceability, acousticness, bpm / 200.0, bright, punch, perc_ratio, zcr * 10, mode]
    features += [float(v) for v in mfcc.mean(axis=1)]
    features += [float(v) for v in mfcc.std(axis=1)[:5]]

    return Analysis(
        bpm=round(bpm, 1),
        energy=round(energy, 3),
        valence=round(valence, 3),
        danceability=round(danceability, 3),
        acousticness=round(acousticness, 3),
        features=[round(f, 4) for f in features],
        mood=mood,
        mood_scores=scores,
    )
