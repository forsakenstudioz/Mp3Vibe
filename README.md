# Vibe (Mp3Vibe)

Your own music streaming app, built from a folder on your laptop.

- **One app for Android, Windows, macOS and Linux**, built from a single Flutter codebase.
- **Online and offline.** Stream anything in your library, or download songs to play without internet. Liked songs can be kept offline automatically.
- **Add a song to your laptop folder and it's in the app.** A small sync program uploads it and the app updates live.
- **Mood-based suggestions.** Every song is analysed for tempo, energy, brightness and key, then tagged Energetic (gaana and mass songs), Party, Calm, Romantic, Sad or Focus. Pick a mood to start a mix, or let the smart queue follow what's playing. It learns from your likes and skips.
- **Listening rooms.** Create a room and share the code. Everyone hears the same song at the same moment, within a fraction of a second. Rooms have a shared queue, chat and live emoji reactions. When the queue runs out, the room DJ picks a song that fits the vibe.

**To set it up, follow [docs/SETUP.md](docs/SETUP.md).** No server experience is needed, and everything runs on free plans.

## How it fits together

```
 Your laptop                       Cloud (free tiers)                     Your devices
┌──────────────────┐          ┌───────────────────────────┐          ┌────────────────────┐
│ Music folder     │          │ Cloudflare R2             │  audio   │ Vibe app           │
│   │              │  upload  │  private bucket of songs ─┼─────────▶│  (Flutter)         │
│   ▼              ├─────────▶│                           │          │                    │
│ sync_agent       │          │ Supabase                  │          │ Home · Library     │
│  • reads tags    │  song    │  • songs table  ──────────┼─live────▶│ Rooms · Downloads  │
│  • mood analysis ├─────────▶│  • logins, likes, history │          │                    │
│  • watches folder│  rows    │  • sign-url function ─────┼─links───▶│ offline cache      │
└──────────────────┘          │  • Realtime rooms ◀───────┼─sync────▶│ on each device     │
                              └───────────────────────────┘          └────────────────────┘
```

## Repo layout

| Path | What's there |
|---|---|
| `app/` | Flutter app. Logic lives in `lib/services/` and screens in `lib/ui/`. |
| `sync_agent/` | Python program that runs on the laptop: `vibe_sync.py` (watch and upload) and `analyze.py` (mood detection). |
| `supabase/migrations/` | Database tables and security rules. Paste into the Supabase SQL editor. |
| `supabase/functions/sign-url/` | Edge function that hands out temporary download links. |
| `.github/workflows/` | `ci.yml` runs checks. `release.yml` builds the app for every platform. |

## How room sync works

Every device in a room shares one small state: *song X was at position P at server time T, playing or paused*, plus the queue. Each device measures how far its clock is from the Supabase server's clock, works out where the song should be right now, and adjusts its own player. Small gaps are fixed by playing up to 3% faster or slower, which nobody can hear. Gaps over 0.4 seconds are fixed by jumping. New songs are scheduled 1.5 seconds ahead so every device can buffer and start together. Any member can change the state. Each change carries a version number and the highest one wins, so simultaneous button presses settle the same way on every device.

## Development

```bash
# App
cd app
flutter pub get
flutter run -d windows      # or linux, macos, or an Android device
flutter test

# Sync agent
cd sync_agent
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt pytest
python -m pytest tests
python vibe_sync.py --once  # needs config.toml
```

Without build-time defines, the app asks for the Supabase URL and publishable key on first launch. Release builds get them from the `VIBE_SUPABASE_URL` and `VIBE_SUPABASE_KEY` repository variables.
