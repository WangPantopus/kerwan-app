# Kerwan — Developer Setup Guide

> **Goal:** from zero to running the full app (capture, classification, search, billing) in under an hour on a fresh macOS machine.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Clone & initial setup](#2-clone--initial-setup)
3. [System dependencies](#3-system-dependencies)
4. [Building the project](#4-building-the-project)
5. [Running tests](#5-running-tests)
6. [Running the app locally](#6-running-the-app-locally)
7. [Environment & config](#7-environment--config)
8. [Backend setup (kerwan-api)](#8-backend-setup-kerwan-api)
9. [Chrome extension](#9-chrome-extension)
10. [Common issues & troubleshooting](#10-common-issues--troubleshooting)
11. [Architecture overview](#11-architecture-overview)
12. [Contributing guidelines](#12-contributing-guidelines)

---

## 1. Prerequisites

### macOS

| Requirement | Minimum | Recommended |
|---|---|---|
| macOS | 13.0 Ventura | 14.x Sonoma |
| RAM | 8 GB | 16 GB |
| Free disk | 10 GB | 20 GB |
| CPU | Intel or Apple Silicon | Apple Silicon (M1+) |

> Apple Silicon is strongly preferred. Ollama LLM inference and whisper.cpp transcription are 3–5× faster on the Neural Engine.

### Xcode

Install **Xcode 15.0 or later** from the Mac App Store.

```bash
# After installing Xcode from the App Store:
sudo xcode-select --switch /Applications/Xcode.app
xcode-select --print-path   # should print /Applications/Xcode.app/Contents/Developer
xcodebuild -version         # should show Xcode 15.x
swift --version             # should show Swift 5.9+
```

Also install the Xcode Command Line Tools if not already present:

```bash
xcode-select --install
```

### Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, follow the instructions to add Homebrew to your `PATH` (Apple Silicon):

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

---

## 2. Clone & initial setup

```bash
git clone https://github.com/<your-org>/kerwan-app.git
cd kerwan-app
```

The repository is a **Swift Package Manager monorepo** — there is no `.xcodeproj`.
Xcode generates a temporary workspace automatically when you open `Package.swift`.

### Open in Xcode (recommended for development)

```bash
open Package.swift
```

Xcode will resolve all SPM dependencies (SQLite.swift, Sparkle) on first open. This takes 1–3 minutes on a first clone.

### Verify the package graph

```bash
swift package show-dependencies
```

Expected top-level dependencies:

```
kerwan-app
├── SQLite.swift (0.15.x)
└── Sparkle (2.x)
```

---

## 3. System dependencies

### 3.1 SQLCipher

SQLCipher is the encrypted SQLite drop-in used in production. The SPM package references it as a system library (via `Vendor/SQLCipher/module.modulemap`).

```bash
brew install sqlcipher
```

After installation, expose the pkg-config path so SPM can locate it:

```bash
# Add to ~/.zprofile or ~/.zshrc
export PKG_CONFIG_PATH="$(brew --prefix sqlcipher)/lib/pkgconfig:$PKG_CONFIG_PATH"
```

Then reload your shell or run `source ~/.zprofile`.

> **Dev note:** During local development the app links against the system `sqlite3` — the SQLCipher PRAGMAs (`PRAGMA key`, `PRAGMA cipher_page_size`) are no-ops on unencrypted SQLite.  The database is only encrypted when SQLCipher is linked (production build).  Unit tests use an in-memory database and are not affected.

### 3.2 Ollama

Ollama runs locally and serves the LLM that classifies events, extracts contacts/promises, generates briefings, and produces embeddings for semantic search.

```bash
# Install Ollama
brew install ollama

# Or download from https://ollama.ai/download/mac
# (The .dmg installer is equivalent and sets up the menubar helper)
```

**Pull the required models:**

```bash
# Start the Ollama server (one-time; after install it auto-starts at login)
ollama serve &

# Classification and briefing model (choose one)
ollama pull llama3          # 4.7 GB — recommended
# ollama pull mistral       # 4.1 GB — alternative, slightly faster

# Embedding model (required for semantic search)
ollama pull nomic-embed-text   # 274 MB

# Verify both are available
ollama list
```

Expected output:
```
NAME                    ID              SIZE    MODIFIED
llama3:latest           ...             4.7 GB  ...
nomic-embed-text:latest ...             274 MB  ...
```

> The app manages Ollama as a **managed subprocess** — it starts, monitors, and stops Ollama automatically. You do NOT need to run `ollama serve` manually when using the app. You only need it running for the integration tests.

### 3.3 Whisper model

The `WhisperService` XPC process transcribes audio using [whisper.cpp](https://github.com/ggerganov/whisper.cpp). It reads GGML model files from:

```
~/Library/Application Support/Kerwan/Models/
```

Download a model (pick one based on your hardware):

```bash
MODEL_DIR="$HOME/Library/Application Support/Kerwan/Models"
mkdir -p "$MODEL_DIR"

# ggml-base.en.bin — 142 MB, fastest, English only (recommended for development)
curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
  -o "$MODEL_DIR/ggml-base.en.bin"

# ggml-small.en.bin — 466 MB, better accuracy, still fast on Apple Silicon
# curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin" \
#   -o "$MODEL_DIR/ggml-small.en.bin"
```

The app auto-detects models in this directory and shows them in **Settings → General → Transcription Model**.

> Without a model file, audio capture still works (events are queued) but transcription is skipped until a model is selected.

---

## 4. Building the project

### 4.1 Swift build (CLI)

```bash
# Set PKG_CONFIG_PATH if you haven't added it to your shell profile:
export PKG_CONFIG_PATH="$(brew --prefix sqlcipher)/lib/pkgconfig:$PKG_CONFIG_PATH"

# Debug build (fast; what you use during development)
swift build --configuration debug

# Release build (optimised; matches what CI produces)
swift build --configuration release
```

A successful debug build outputs three executables:

```
.build/debug/Kerwan          (main app)
.build/debug/WhisperService  (XPC service)
.build/debug/kerwan-nmh      (Chrome Native Messaging Host)
```

### 4.2 xcodebuild (full app stack)

For changes that touch `@Observable` views, Sparkle, or SwiftUI — which require the full Xcode build system:

```bash
xcodebuild build \
  -scheme Kerwan \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  | grep -E "error:|warning:|Build "
```

> The `xcodebuild` path is exercised by the `xcode-test` CI job on every PR.

---

## 5. Running tests

### 5.1 Quick test run (all unit tests)

```bash
export PKG_CONFIG_PATH="$(brew --prefix sqlcipher)/lib/pkgconfig:$PKG_CONFIG_PATH"

swift test \
  --filter "KerwanStorageTests|KerwanKeychainTests|KerwanExclusionTests|KerwanCaptureTests|KerwanScoringTests|KerwanTests" \
  --jobs 1
```

> `--jobs 1` prevents SQLite file-locking races in the storage tests.

**Expected result:** ~729 tests, 0 failures, 6 skipped (sqlite-vec extension not available in stock macOS SQLite).

### 5.2 Individual test targets

Run targets in isolation when working on a specific module:

```bash
swift test --filter KerwanStorageTests    # SQLite persistence, migrations, CRUD
swift test --filter KerwanKeychainTests   # Keychain read/write/delete
swift test --filter KerwanExclusionTests  # Privacy exclusion rules
swift test --filter KerwanCaptureTests    # Raw event buffer
swift test --filter KerwanScoringTests    # Relationship score engine
swift test --filter KerwanTests           # Main app: search, billing, classification, identity, license
```

### 5.3 Integration tests (requires Ollama)

Integration tests are **excluded from CI** (`CI=true` gates them out of the build). Run them locally after starting Ollama:

```bash
ollama serve &   # if not already running
swift test --filter KerwanIntegrationTests   # no CI=true
```

These tests verify the full pipeline: capture → classification → storage → search. They take 2–5 minutes.

### 5.4 Performance tests

```bash
swift test --filter KerwanPerformanceTests
```

These run slow timer-based tests (session clustering with 5 000 events, search latency). Only run manually.

### 5.5 What's skipped and why

| Skipped test class | Reason |
|---|---|
| `StorageActorVectorTests.*` (6 tests) | sqlite-vec extension requires loading `sqlite_vec.dylib`; not available in stock macOS sqlite3. Run in a build that loads the extension at startup. |
| `KerwanIntegrationTests` | Require a running Ollama instance and a real macOS Keychain entitlement. Excluded from CI via `CI=true` environment variable in Package.swift. |
| `KerwanPerformanceTests` | Slow wall-clock timers. Excluded from CI. |

---

## 6. Running the app locally

### 6.1 First run from Xcode

1. Open `Package.swift` in Xcode.
2. Select the **Kerwan** scheme from the scheme picker (top toolbar).
3. Set the destination to **My Mac**.
4. Press **⌘R** to build and run.

The app launches in the **menu bar** (look for the K icon, top-right).

### 6.2 Permissions to grant

macOS will prompt for each permission the first time the relevant feature is used. Grant all of them for full functionality:

| Permission | Where to grant | Required for |
|---|---|---|
| **Microphone** | System Settings → Privacy & Security → Microphone | Audio capture + transcription |
| **Screen Recording** | System Settings → Privacy & Security → Screen Recording | App/window context during capture |
| **Accessibility** | System Settings → Privacy & Security → Accessibility | Keyboard activity detection |
| **Contacts** | System Settings → Privacy & Security → Contacts | Linking captured interactions to contacts |
| **Calendars** | System Settings → Privacy & Security → Calendars | Meeting detection from calendar events |
| **Full Disk Access** | System Settings → Privacy & Security → Full Disk Access | Reading mail databases (optional) |

> If a permission is denied and you want to re-grant it: remove Kerwan from the list in System Settings and relaunch the app — it will re-prompt.

### 6.3 First-launch setup

1. Click the menu bar icon → **Open Kerwan**.
2. Complete the **onboarding** flow (permissions review, model selection).
3. Set up Ollama in **Settings → General → AI Model** — select `llama3` from the dropdown.
4. Click **Start Capturing** in the menu bar to begin.

The app will:
- Start the `WhisperService` XPC process.
- Launch and monitor Ollama as a managed subprocess.
- Begin writing to `~/Library/Application Support/Kerwan/kerwan.db`.

### 6.4 Useful keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘⇧R` | Open global semantic search overlay |
| `⌘⇧N` | Open quick note panel |
| `⌘0` | Bring main window to front |
| `⌘,` | Open Settings |

### 6.5 Resetting local state

To start completely fresh (wipe the database + all settings):

```bash
# Stop the app first, then:
rm -rf "$HOME/Library/Application Support/Kerwan"
# Keychain items (license key, db passphrase) are removed from Keychain Access.app:
#   Open Keychain Access → search "Kerwan" → delete all entries
```

---

## 7. Environment & config

### 7.1 No `.env` file needed for the macOS app

The macOS app reads all configuration from:
- **macOS Keychain** — license key (`kerwan.license.key`), database passphrase (`kerwan.db.passphrase`), OAuth tokens
- **UserDefaults** — UI preferences, exclusion rules, model selection
- **`~/Library/Application Support/Kerwan/`** — database file, whisper models, Unix socket

No `.env` file or environment variables are required to build or run the macOS app.

### 7.2 Key Keychain items

| Keychain item | Key constant | Contents |
|---|---|---|
| License key | `kerwan.license.key` | Raw license key string (`KERWAN-XXXX-...`) |
| DB passphrase | `kerwan.db.passphrase` | AES-256 key for SQLCipher (auto-generated on first run) |
| License cache | `kerwan.license.cache` | JSON-encoded `LicenseCacheEntry` (7-day TTL) |

You can inspect these in **Keychain Access.app** (search "kerwan").

### 7.3 Ollama URL override

The app connects to Ollama at `http://127.0.0.1:11434` by default. To point to a different Ollama instance (e.g., remote test server):

```bash
# Not implemented as a public setting yet — change the constant in:
# Kerwan/Sources/AI/OllamaClient.swift → static let baseURL
```

### 7.4 Database location

```
~/Library/Application Support/Kerwan/kerwan.db
```

You can inspect it with the sqlite3 CLI (note: unencrypted in dev mode):

```bash
sqlite3 "$HOME/Library/Application Support/Kerwan/kerwan.db" ".tables"
```

---

## 8. Backend setup (kerwan-api)

The `kerwan-api` backend handles license key validation, Stripe billing, and update distribution. You only need it locally if you're testing the **license validation flow** or **Stripe webhooks**.

The backend lives in `kerwan-api/nifty-hypatia/` (Node.js + TypeScript + Fastify + Prisma + PostgreSQL).

### 8.1 Prerequisites

```bash
node --version   # 20.x required
npm --version    # 9.x+

# If not installed:
brew install node@20
echo 'export PATH="/opt/homebrew/opt/node@20/bin:$PATH"' >> ~/.zprofile
source ~/.zprofile
```

### 8.2 Option A — Docker Compose (recommended)

The easiest way to run the full backend stack locally:

```bash
cd kerwan-api/nifty-hypatia
cp .env.example .env
# Edit .env — fill in at minimum:
#   STRIPE_SECRET_KEY=sk_test_...
#   STRIPE_WEBHOOK_SECRET=whsec_...   (from stripe listen --forward-to)
#   RESEND_API_KEY=re_...             (or leave dummy value for non-email testing)

docker compose up
```

This starts:
- `postgres:15-alpine` on port `5432` (credentials: `kerwan`/`kerwan_dev`)
- `kerwan-api` on port `3000` (runs `prisma migrate deploy` then `npm run dev`)

Verify it's healthy:

```bash
curl http://localhost:3000/api/health
# → {"status":"ok","version":"..."}
```

### 8.3 Option B — Native (no Docker)

```bash
cd kerwan-api/nifty-hypatia

# Install a local PostgreSQL
brew install postgresql@15
brew services start postgresql@15
createdb kerwan_dev

# Install Node dependencies
npm install

# Copy and configure environment
cp .env.example .env
# Edit .env — set DATABASE_URL=postgresql://$(whoami)@localhost:5432/kerwan_dev

# Run migrations and start dev server
npm run db:migrate
npm run dev
```

### 8.4 Point the macOS app at your local backend

The macOS app validates licenses against `https://api.kerwan.app` by default. To use your local backend:

```bash
# In Kerwan/Sources/License/LicenseManager.swift:
# Change: static let backendBaseURL = URL(string: "https://api.kerwan.app")!
# To:     static let backendBaseURL = URL(string: "http://localhost:3000")!
```

> Don't commit this change — it's local only. A `DEBUG`-gated override is a good future improvement.

### 8.5 Stripe webhook forwarding (optional)

For testing the full checkout → license activation flow:

```bash
# Install the Stripe CLI
brew install stripe/stripe-cli/stripe
stripe login

# Forward webhooks to your local backend
stripe listen --forward-to localhost:3000/api/webhooks/stripe
# Copy the webhook signing secret (whsec_...) into .env STRIPE_WEBHOOK_SECRET
```

### 8.6 Creating a test license key

```bash
# Using the API directly (no UI needed):
curl -X POST http://localhost:3000/api/license/activate \
  -H 'Content-Type: application/json' \
  -d '{"key": "KERWAN-TEST-0000-0000-0001", "machineId": "dev-machine"}'
```

---

## 9. Chrome extension

The extension scrapes LinkedIn and Gmail in the browser and forwards data to the macOS app via the `kerwan-nmh` Native Messaging Host.

### 9.1 Install the Native Messaging Host manifest

The NMH manifest tells Chrome where to find the `kerwan-nmh` binary. Install it with:

```bash
# Build the NMH binary first
swift build --configuration debug

# Install the manifest (points Chrome to .build/debug/kerwan-nmh)
NMH_BINARY="$(pwd)/.build/debug/kerwan-nmh"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_DIR/com.kerwan.app.json" <<EOF
{
  "name": "com.kerwan.app",
  "description": "Kerwan native messaging host",
  "path": "$NMH_BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://YOUR_EXTENSION_ID/"]
}
EOF
```

> Replace `YOUR_EXTENSION_ID` after loading the extension (step 9.2 below).

### 9.2 Load the extension in Chrome developer mode

1. Open Chrome → address bar → `chrome://extensions`
2. Enable **Developer mode** (top-right toggle).
3. Click **Load unpacked**.
4. Navigate to `<repo-root>/ChromeExtension/` and click **Open**.
5. Note the extension ID shown below the extension card (e.g., `abcdefghijklmnopqrstuvwxyz012345`).
6. Update the `allowed_origins` in the manifest installed in step 9.1:

```bash
# Replace YOUR_EXTENSION_ID with the actual ID from Chrome:
sed -i '' "s/YOUR_EXTENSION_ID/abcdefghijklmnopqrstuvwxyz012345/" \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.kerwan.app.json"
```

7. Restart Chrome (fully quit and reopen) for the NMH manifest to take effect.

### 9.3 Verify the extension is connected

1. Ensure the Kerwan app is running (it opens the Unix socket at `~/Library/Application Support/Kerwan/chrome-bridge.sock`).
2. Click the **K** extension icon in the Chrome toolbar.
3. The popup should show **Status: Connected**.

### 9.4 Test data flow

1. Visit any LinkedIn profile page (`linkedin.com/in/...`).
2. Check the Kerwan app → **Today** tab — the contact should appear within a few seconds.
3. Open a Gmail thread → same result.

> If the popup shows **Disconnected**, see [§10 — Troubleshooting: Chrome extension](#chrome-extension-shows-disconnected).

---

## 10. Common issues & troubleshooting

### Build fails: `module 'SQLCipher' not found`

**Cause:** `PKG_CONFIG_PATH` is not set or SQLCipher is not installed.

```bash
brew install sqlcipher
export PKG_CONFIG_PATH="$(brew --prefix sqlcipher)/lib/pkgconfig:$PKG_CONFIG_PATH"
swift package resolve
swift build
```

Add the export to `~/.zprofile` so it persists across shell sessions.

---

### Build fails: stale PCH module cache

**Symptom:**
```
PCH was compiled with module cache path '/path/to/old/workspace/...'
error: could not build Objective-C module 'SQLCipher'
```

**Fix:**
```bash
rm -rf .build
swift build
```

---

### `swift test` fails: `KerwanIntegrationTests` compile errors

**Cause:** Running `swift test` without `CI=true` tries to compile the integration test target, which references types that don't exist in the current scope.

**Fix:** Always set `CI=true` when running the standard test suite:

```bash
CI=true swift test --filter "KerwanStorageTests|KerwanTests|..."
```

Or run only the specific targets you need (see §5.2).

---

### Xcode: `Package.resolved` conflicts after opening

**Cause:** Xcode sometimes regenerates `Package.resolved` with different checksums.

**Fix:**

```bash
# Reset to the committed resolved file:
git checkout Package.resolved
# Then in Xcode: File → Packages → Reset Package Caches
```

---

### Ollama not detected by the app

**Symptom:** Settings → AI shows "Ollama: Not running" even after `brew install ollama`.

**Check:**

```bash
curl http://127.0.0.1:11434/api/tags
# Should return a JSON list of models
```

If that fails, start Ollama manually:

```bash
ollama serve
```

If Ollama starts but shows no models, pull them:

```bash
ollama pull llama3
ollama pull nomic-embed-text
```

---

### App crashes immediately at launch

**Likely cause:** Missing microphone or accessibility permissions after a fresh install.

**Check:** Open Console.app, filter by process "Kerwan", look for `AVCaptureDevice` or `AXIsProcessTrusted` errors.

**Fix:** Grant permissions in System Settings → Privacy & Security, then relaunch.

---

### WhisperService XPC not starting

**Symptom:** Audio is captured but never transcribed.

**Check:**

```bash
log show --predicate 'subsystem == "com.kerwan.app"' --last 5m | grep -i whisper
```

**Common cause:** The `ggml-*.bin` model file is missing from `~/Library/Application Support/Kerwan/Models/`. Download one (see §3.3).

---

### Chrome extension shows "Disconnected"

**Checklist:**

1. Is the Kerwan app running? (Check menu bar for K icon.)
2. Does the socket exist?
   ```bash
   ls -la "$HOME/Library/Application Support/Kerwan/chrome-bridge.sock"
   ```
3. Does the NMH manifest point to the correct binary?
   ```bash
   cat "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.kerwan.app.json"
   ```
4. Does the extension ID in the manifest match the installed extension ID in `chrome://extensions`?
5. Did you fully quit and reopen Chrome after installing the manifest?

---

### Database locked / storage errors

**Cause:** Two Kerwan processes running simultaneously (common after crashes during development).

```bash
# Find and kill any stale Kerwan processes:
pkill -f "\.build/debug/Kerwan"
# Or for release builds:
pkill -f "Kerwan.app"
```

---

### `xcodebuild test` fails with scheme not found

```bash
# List available schemes:
xcodebuild -list 2>&1 | head -20

# If "Kerwan" isn't listed, reset the SPM package:
# Xcode → File → Packages → Reset Package Caches
```

---

### License validation fails locally

If testing license validation and the app returns "network error":

1. Ensure the local backend is running: `curl http://localhost:3000/api/health`
2. Change `LicenseManager.backendBaseURL` to `http://localhost:3000` (see §8.4).
3. The app caches the last valid license for 7 days — to force a fresh validation, delete the Keychain item `kerwan.license.cache`.

---

## 11. Architecture overview

### The 3-process model

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Kerwan.app  (main process — SwiftUI + AppKit)                           │
│                                                                          │
│  CaptureManager ─ reads microphone, accessibility, calendar, mail       │
│  ClassificationActor ─ batches raw events → Ollama for LLM processing  │
│  StorageActor ─ async SQLite actor; all DB access goes through here      │
│  BriefingScheduler ─ nightly AI-generated daily summary                 │
│  LicenseManager ─ validates license online (7-day cache in Keychain)    │
│  RelationshipScoreEngine ─ nightly scoring of contact interactions      │
│  NativeMessagingBridge ─ Unix socket server for Chrome extension data   │
│                                                                          │
│          ▼ NSXPCConnection (async/await via WhisperServiceAsyncProxy)   │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  WhisperService.xpc  (crash-isolated XPC service)                 │  │
│  │  Loads ggml-*.bin model via whisper.cpp, transcribes PCM audio    │  │
│  │  Metal-accelerated on Apple Silicon                                │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│          ▼ Managed subprocess (launched/monitored by AppLifecycle)      │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Ollama  (localhost:11434)                                         │  │
│  │  llama3 — classification, promise extraction, briefings           │  │
│  │  nomic-embed-text — 768-dim vectors for semantic search           │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘

Chrome Extension ──(stdin/stdout NM protocol)──► kerwan-nmh binary
kerwan-nmh ──(Unix domain socket)──────────────► Kerwan.app NativeMessagingBridge
```

**Why 3 processes?**

- **XPC isolation:** A whisper.cpp crash (e.g., bad model file, Metal fault) kills only the XPC service — the main app recovers and restarts the service without losing captured data.
- **Ollama subprocess:** Ollama is a pre-built binary that manages its own GPU memory. Running it as a subprocess (not XPC) means the app can start/stop/restart it without user interaction.
- **Security boundary:** The NMH binary is intentionally minimal — it only relays bytes. If it crashes or is compromised, the damage is contained.

### Swift module map

| Module | Path | Responsibility |
|---|---|---|
| `KerwanStorage` | `Sources/KerwanStorage/` | `StorageActor` — all SQLite reads/writes; `Migrations` — schema versioning; `SQLiteConnection` — raw connection + pragma configuration |
| `KerwanKeychain` | `Sources/KerwanKeychain/` | `KeychainManager` — typed read/write/delete for all Keychain items |
| `KerwanExclusion` | `Sources/KerwanExclusion/` | `ExclusionEngine` — pattern matching against user-defined exclusion rules |
| `KerwanCapture` | `Sources/KerwanCapture/` | `RawEventBuffer` — concurrent buffer for incoming events before DB write |
| `KerwanScoring` | `Sources/KerwanScoring/` | `RelationshipScoreEngine` — nightly scoring; `NightlyScoringScheduler` — timer |
| `KerwanXPCProtocol` | `KerwanXPCProtocol/` | `WhisperServiceProtocol` — `@objc` XPC interface; `TranscriptSegment` — codable data model |
| `Kerwan` (executable) | `Kerwan/Sources/` | All app-level code: UI, AI pipeline, billing, identity, license, search |
| `WhisperService` (executable) | `WhisperService/Sources/` | XPC service entry point + transcription handler |
| `kerwan-nmh` (executable) | `KerwanNMH/Sources/` | Native Messaging Host: stdin/stdout framing + Unix socket relay |

### Data flow

```
Audio/Accessibility/Calendar/Browser
        ↓
  CaptureManager → RawEvent (unclassified)
        ↓  (batch every N seconds)
  ClassificationActor → Ollama (Llama 3)
        ↓  (structured JSON response)
  Interaction / Contact / Promise / WorkSession → StorageActor → SQLite
        ↓  (query time)
  SearchEngine → keyword (FTS5) + semantic (sqlite-vec/KNN) → SearchResult[]
```

### Key design principles

1. **Privacy-first, local-only.** No user data ever leaves the device. Ollama and whisper.cpp run entirely on-device.
2. **Graceful degradation.** If Ollama is unavailable, capture continues. If Whisper fails, audio is discarded but the session is not lost. If the license server is unreachable, the cached license is used.
3. **Actor-based concurrency.** `StorageActor`, `ClassificationActor`, `KeychainManager` are all Swift actors — no locks, no data races.
4. **Crash resilience.** `CrashRecoveryManager` detects dirty shutdowns (file lock not released) and runs a WAL checkpoint + integrity check at the next launch.

---

## 12. Contributing guidelines

### Branch naming

| Branch type | Pattern | Example |
|---|---|---|
| Feature | `feature/<ticket-or-short-desc>` | `feature/P-050-export-csv` |
| Bug fix | `fix/<short-desc>` | `fix/session-timer-drift` |
| Refactor | `refactor/<scope>` | `refactor/storage-actor` |
| Docs | `docs/<what>` | `docs/update-development-guide` |
| Release | `release/<version>` | `release/1.2.0` |
| Hotfix | `hotfix/<short-desc>` | `hotfix/license-cache-expiry` |

### Branch flow

```
feature/* ──PR──► dev ──PR──► staging ──PR──► master (production)
                  ↑                             ↑
              CI required                CI + deploy required
```

- **Never push directly to `master` or `dev`.**
- All changes go through a PR.
- PRs require CI green before merge.
- `dev` → `staging` PRs should be smoke-tested on the staging API URL.

### PR checklist

Before opening a PR, verify locally:

```bash
# 1. All tests pass
CI=true swift test \
  --filter "KerwanStorageTests|KerwanKeychainTests|KerwanExclusionTests|KerwanCaptureTests|KerwanScoringTests|KerwanTests" \
  --jobs 1

# 2. Release build compiles
swift build --configuration release

# 3. No obvious SwiftLint issues (if .swiftlint.yml is present)
swiftlint lint
```

PR description should include:
- **What** changed (1–3 bullet points)
- **Why** (motivation / ticket reference)
- **Test plan** (how you verified the change)
- Screenshots for any UI changes.

### CI requirements

The CI pipeline (`.github/workflows/ci.yml`) runs on every PR:

| Job | What it checks | Must pass? |
|---|---|---|
| `spm-test` | All unit tests, code coverage | **Yes** |
| `xcode-test` | Full app stack via xcodebuild | **Yes** |
| `lint` | SwiftLint (advisory) | No (continue-on-error) |

PRs **cannot be merged** if `spm-test` or `xcode-test` is red.

### Commit style

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat:     new user-facing capability
fix:      bug fix
test:     add or update tests
refactor: code change without behaviour change
docs:     documentation only
ci:       CI/CD workflow changes
chore:    build scripts, dependency updates
perf:     performance improvement
```

Example:
```
feat(search): add date-range filter to mergeAndRank

Previously the date filter was only applied after the RRF merge.
Now filtering happens before scoring so stale results don't
inflate RRF ranks.

Closes #P-051
```

### Adding a new SPM target

1. Add the target to `Package.swift`.
2. Create `Sources/<TargetName>/` with at least one `.swift` file.
3. Add a corresponding test target (`Tests/<TargetName>Tests/`).
4. Add the new test target to the `--filter` in CI (`ci.yml` → `spm-test` job).
5. Update this file's [Module map](#swift-module-map) table.

### Adding a migration

Database schema changes are handled by `Sources/KerwanStorage/Migrations.swift`.

1. Add a new `migration_NNN` function following the existing pattern.
2. Register it in the `migrations` array with an incremented version number.
3. Update `schemaVersion` in `StorageActor`.
4. Write a test in `KerwanStorageTests` that verifies the migration applies cleanly to an empty schema and to a schema at the previous version.
5. **Never modify an existing migration** — add a new one instead.

---

*Last updated: 2026-03-25 · Maintained by the Kerwan engineering team.*
