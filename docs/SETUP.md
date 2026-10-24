# Setting up Vibe

This guide takes you from nothing to music playing on your phone and laptop. You don't need any server experience. Everything runs on free plans, and the guide tells you exactly where to click.

It takes about 45 minutes the first time. You do it once.

**What you'll set up**

| Piece | What it does | Cost |
|---|---|---|
| Supabase | Song list, logins, live rooms | Free |
| Cloudflare R2 | Stores the music files | Free up to 10 GB (around 2,500 songs) |
| Sync program on your laptop | Uploads new songs from your music folder | Free |
| GitHub Actions | Builds the app for Android, Windows, Mac and Linux | Free |

Keep a notes file open while you go. You'll copy several values into it along the way.

---

## Step 1: Supabase (song list, logins, rooms)

1. Go to <https://supabase.com> and click **Start your project**. Sign up with GitHub (easiest).
2. Click **New project**.
   - **Name:** `vibe`
   - **Database password:** click **Generate a password**. You won't need it again, but save it in your notes anyway.
   - **Region:** pick the one closest to you (for India, choose **Mumbai**).
   - Click **Create new project** and wait about a minute.
3. **Create the database tables.**
   - In the left sidebar, open **SQL Editor**, then click **New query**.
   - Open [`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql) from this repo, copy all of it, and paste it in.
   - Click **Run**. You should see "Success. No rows returned".
4. **Copy your keys.** Go to **Project Settings** (gear icon), then **API Keys** (on some layouts it's **Data API**). Save these three values in your notes:
   - **Project URL**, which looks like `https://abcdxyz.supabase.co`
   - **Publishable key** (`sb_publishable_...`). If you only see "anon public", use that instead.
   - **Secret key** (`sb_secret_...`). If you only see "service_role", use that instead. **Keep this one private.** Anyone who has it can change your library.
5. **Make the app invite-only.** Go to **Authentication**, then **Sign In / Providers**, and turn **off** "Allow new users to sign up". Leave **Email** enabled.
6. **Create your own account.** Go to **Authentication**, then **Users**, then **Add user**, then **Create new user**. Enter your email and a password, tick **Auto Confirm User**, and click **Create user**.

## Step 2: Cloudflare R2 (where the music files live)

1. Go to <https://dash.cloudflare.com/sign-up> and create a free account.
2. In the left sidebar, open **R2 Object Storage** and click **Get started** or **Purchase R2**.
   Cloudflare asks for a card or PayPal before it turns R2 on, even on the free plan. You won't be charged unless you go over 10 GB of storage. Streaming is always free.
3. Click **Create bucket**. Name it `vibe-music`, leave the other settings as they are, and click **Create bucket**.
4. Go back to **R2 Object Storage** and copy the **Account ID** shown on the right side into your notes.
5. Click **Manage API tokens** (under "Account details" on the right), then **Create Account API token**:
   - **Token name:** `vibe`
   - **Permissions:** **Object Read & Write**
   - **Specify bucket(s):** choose **Apply to specific buckets only** and pick `vibe-music`
   - Click **Create API Token**.
   - Copy the **Access Key ID** and **Secret Access Key** into your notes. The secret is shown only once.

## Step 3: The download-link function (connects the app to R2)

The music bucket is private. This small function hands out temporary links, and only to people who are signed in.

1. In Supabase, open **Edge Functions** in the left sidebar.
2. Click **Deploy a new function**, then choose **Via Editor**.
3. Name it exactly `sign-url`.
4. Delete the example code. Paste in everything from [`supabase/functions/sign-url/index.ts`](../supabase/functions/sign-url/index.ts), then click **Deploy function**.
5. Open the function's **Settings** (or **Details**). If you see an option called **Verify JWT** or **Enforce JWT verification**, turn it **off** and save. The function already checks sign-in itself, and this setting can block the newer key types.
6. Go to **Edge Functions**, then **Secrets** (sometimes under **Manage secrets**), and add these four:

   | Name | Value |
   |---|---|
   | `R2_ACCOUNT_ID` | your Cloudflare Account ID |
   | `R2_ACCESS_KEY_ID` | the R2 Access Key ID |
   | `R2_SECRET_ACCESS_KEY` | the R2 Secret Access Key |
   | `R2_BUCKET` | `vibe-music` |

## Step 4: The sync program on your laptop

This program watches your music folder. Whenever you add a song, it works out the song's mood, uploads it, and the song appears in the app within seconds.

### Windows

1. Install **Python 3.12** from <https://www.python.org/downloads/>. On the first installer screen, tick **"Add python.exe to PATH"**.
2. Optional, but recommended if you have `.m4a` or `.aac` files: open **Command Prompt** and run `winget install ffmpeg`.
3. Download this repo. On the GitHub page, click **Code**, then **Download ZIP**, and unzip it somewhere permanent, such as `Documents\Mp3Vibe`.
4. Open the `sync_agent` folder. Copy `config.example.toml`, rename the copy to `config.toml`, and open it in Notepad.
5. Fill it in:
   - `music_folder`: your music folder, written with forward slashes, for example `"C:/Users/zoro/Music/MySongs"`
   - `[supabase]`: the Project URL and the **secret** key
   - `[r2]`: the Account ID, Access Key ID and Secret Access Key, with `bucket = "vibe-music"`
6. Double-click **`start_sync.bat`**. The first run installs what it needs (a few minutes), then uploads your whole library. You'll see each song as it's added. A big library can take a while the first time, and you can start using the app while it runs.
7. **Start it automatically with Windows:** press **Win+R**, type `shell:startup`, and press Enter. Right-click `start_sync.bat`, choose **Create shortcut**, and drag the shortcut into the folder that opened.

### macOS or Linux

1. Install Python 3.12 or newer. On a Mac: install from python.org, or run `brew install python ffmpeg`.
2. Download the repo and fill in `sync_agent/config.toml` as in steps 4 and 5 above (for example `music_folder = "~/Music/MySongs"`).
3. In Terminal, run `cd path/to/Mp3Vibe/sync_agent` and then `./start_sync.sh`.

### Good to know

- Songs only upload while the laptop is on and the sync program is running. Anything added while it was off gets picked up the next time it starts.
- Deleting a song from the folder hides it in the app. Putting it back brings it back.
- Songs need tags (title and artist) to look nice. Most downloaded songs already have them. If a song has no tags, its file name is used as the title.
- If you think the guessed mood is wrong, change it in the app: open the song's ⋮ menu and tap **Change mood**.
- After a big app update that improves mood detection, run `start_sync.bat --reanalyze` once to re-check every song.

## Step 5: Get the app

GitHub builds the app for every platform for you.

1. In your GitHub repo, go to **Settings**, then **Secrets and variables**, then **Actions**, then the **Variables** tab, and click **New repository variable**. Add two:
   - `VIBE_SUPABASE_URL`: your Supabase Project URL
   - `VIBE_SUPABASE_KEY`: your Supabase **publishable** key (never the secret key)
2. Go to the **Actions** tab. Click **Build app** on the left, then **Run workflow**, then **Run workflow**.
3. Wait about 15 to 20 minutes. When it's done, open **Releases** on the repo's main page and download:
   - **Android:** `Vibe-android.apk`. Open it on your phone and allow "install unknown apps" when asked.
   - **Windows:** `Vibe-windows.zip`. Unzip it and run `vibe.exe`. If SmartScreen warns you, click **More info**, then **Run anyway**.
   - **Mac:** `Vibe-macos.zip`. Unzip it, then right-click **vibe.app** and choose **Open** the first time.
   - **Linux:** `Vibe-linux.tar.gz`. Extract it and run `./vibe`. You need `libmpv` installed (`sudo apt install libmpv2`).
4. Sign in with the email and password from Step 1.6.

Run **Build app** again whenever the code changes to get a new version.

## Step 6: Invite friends to rooms

1. In Supabase, go to **Authentication**, then **Users**, then **Add user**, then **Create new user**. Enter their email and a password, and tick **Auto Confirm User**.
2. Send them the app download and their login.
3. In the app, open the **Rooms** tab and tap **Create a room**. Share the 6-letter code. Everyone who joins hears the same song at the same moment, and anyone can play, skip, queue songs, chat or send reactions.

Everyone you invite can stream your whole library. Only invite people you'd share your music with.

---

## Limits on the free plans

- **Supabase** pauses a free project after about a week with no activity at all. If the app suddenly can't connect, open the Supabase dashboard and click **Restore project**. Using the app regularly keeps it awake.
- **R2** is free up to 10 GB stored. After that it costs about $0.015 per GB each month (around ₹1.3 per GB). Streaming and downloads are always free.

## Troubleshooting

| Problem | Fix |
|---|---|
| App says "Could not load your library" | Check the URL and publishable key you set in Step 5.1. Make sure the SQL in Step 1.3 ran without errors. |
| Songs show up but won't play | The `sign-url` function or its secrets are wrong. In Supabase, go to **Edge Functions**, then `sign-url`, then **Logs** to see the error. Check all four secrets and the JWT setting from Step 3.5. |
| Sync program says `Supabase 401` | The `secret_key` in `config.toml` is wrong, or it's the publishable key by mistake. |
| Sync program says `AccessDenied` or `InvalidAccessKeyId` | Check the R2 keys and the bucket name. The token must have **Object Read & Write** on `vibe-music`. |
| "mood analysis skipped" for some songs | Install ffmpeg (Step 4.2). The song still uploads, it just gets a mood guess from its tags. |
| New song not appearing | Check the sync window for errors, and pull down to refresh in the app. |
