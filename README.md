# Kerwan

A local-first macOS desktop application that passively captures professional activity and converts it into searchable client timelines, billable session suggestions, and relationship memory.

All processing happens on-device. No user data ever leaves the machine.

---

## What It Does

- **Passive capture** — audio (meetings), app activity, email, calendar, and browser context
- **On-device transcription** — real-time meeting transcription via whisper.cpp with Metal acceleration
- **AI classification** — local LLM (Ollama) extracts contacts, promises, topics, and billing signals
- **Client timelines** — every interaction with a client or contact, searchable and summarized
- **Billing suggestions** — work sessions clustered automatically; review and export to invoice
- **Semantic search** — find anything across all your work with natural language queries

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5.9+ |
| UI | SwiftUI (MenuBarExtra, main window, global search overlay) |
| Audio capture | AVAudioEngine + ScreenCaptureKit (CoreAudio) |
| Transcription | whisper.cpp via WhisperKit (XPC service, Metal accelerated) |
| LLM inference | Ollama — Llama 3 8B / Mistral 7B (managed subprocess) |
| Embeddings | nomic-embed-text via Ollama (768-dim vectors) |
| Database | SQLite + SQLCipher (AES-256) + sqlite-vec |
| Email | Gmail OAuth 2.0 + IMAP (read-only) |
| Calendar | EventKit (macOS, read-only) |
| Browser extension | Chrome Manifest V3 (JavaScript) — LinkedIn + Gmail context |
| Native Messaging | Chrome Native Messaging over stdio |
| Backend | Node.js + TypeScript (licensing + Stripe + auto-update only) |
| Backend DB | PostgreSQL |

**System requirements:** macOS 13.0+ · Apple Silicon recommended (Intel supported) · 8 GB RAM minimum, 16 GB recommended · 10 GB free disk space

---

## Repository Structure

```
kerwan-app/
├── Package.swift                # SPM package manifest
├── Kerwan/
│   ├── Sources/
│   │   ├── App/                 # @main App struct, AppState, views
│   │   ├── Models/              # Domain model types
│   │   └── XPCProtocol/         # WhisperServiceProtocol, TranscriptSegment (shared)
│   └── Resources/               # Info.plist, entitlements
├── WhisperService/
│   └── Sources/                 # XPC service entry point and handler
├── Vendor/
│   └── SQLCipher/               # System library module map for SQLCipher
├── KerwanTests/                 # Unit tests
└── KerwanIntegrationTests/      # Integration tests
```

---

## Architecture Overview

Kerwan runs as three cooperating processes:

1. **KerwanApp** (main) — SwiftUI UI, CaptureManager, StorageEngine
2. **WhisperService** (XPC) — whisper.cpp transcription, crash-isolated
3. **Ollama** (managed subprocess) — LLM inference and embedding on localhost:11434

Data flow: Capture → RawEventBuffer → Transcription → Classification → Storage → UI/Search

Full architecture and data model are documented in [`kerwan_engineering_design.md`](./kerwan_engineering_design.md).

---

## Branch Strategy

| Branch | Purpose |
|---|---|
| `master` | Production — tagged releases only |
| `staging` | Pre-release integration and QA |
| `dev` | Active development |

Feature branches cut from `dev`, merged back to `dev` via PR. Promotions: `dev → staging → master`.

---

## Building

### Prerequisites

- macOS 13.0+ (Ventura)
- Xcode 15.0+ with Swift 5.9
- SQLCipher (install via Homebrew):
  ```bash
  brew install sqlcipher
  ```

### Build & Run

```bash
# Resolve dependencies and build
swift build

# Run unit tests
swift test --filter KerwanTests

# Run integration tests
swift test --filter KerwanIntegrationTests
```

### Xcode

To open in Xcode, generate the project:
```bash
open Package.swift
```

Xcode will resolve SPM dependencies automatically. Select the **Kerwan** scheme and run (⌘R).

### Targets

| Target | Type | Description |
|---|---|---|
| `Kerwan` | Executable | Main macOS app (SwiftUI + capture + storage) |
| `WhisperService` | Executable | XPC service for whisper.cpp transcription |
| `KerwanXPCProtocol` | Library | Shared protocol and types for XPC communication |
| `SQLCipher` | System Library | Module map linking against SQLCipher |
| `KerwanTests` | Test | Unit tests |
| `KerwanIntegrationTests` | Test | Integration tests |

---

## Privacy

- All capture and AI inference runs locally. No telemetry, no analytics SDK.
- Database is AES-256 encrypted at rest (SQLCipher). Passphrase stored in macOS Keychain.
- The only outbound network calls are license key validation and update checks (pinned to our domain).
- Ollama and Whisper are bound exclusively to `127.0.0.1`.
