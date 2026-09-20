# UMLive Voice — Architecture

The single document every later task reads before writing code in `apps/mobile`.
It states decisions, not options. If a decision is missing here, the PRD wins and
this file is corrected in the same change.

## 1. What this app is

UMLive Voice is an Android client for a generated Spring Boot backend: the user
points it at a base URL and the app reads that backend's own OpenAPI description
and becomes a Spanish voice assistant over the data the source UML diagram
models.
It drives a backend it has never seen — operations are discovered at runtime,
never hard-coded per diagram, per route or per field.
It keeps working when the network drops: reads are answered from cache, writes
queue durably, and the queue drains in order when the backend answers again.

**Contractual behaviour**: `PRD-MOBILE.md` §5.1 — the four canonical utterances
are the acceptance walkthrough; breaking one is a regression.
**Structure, states and visuals**: `PRD-MOBILE-ux-spec.md`.
**Task list**: `odd/tasks/umlive-voice-flutter-app.md`.

## 2. Architecture — four stages, one spine

```
┌── Voice ─────────────┐   ┌── Resolution ──────────┐   ┌── Execution ─────────┐
│ sherpa STT (offline) │──▶│ online:  proxy → LLM   │──▶│ HTTP client + token  │
│ platform TTS (es-US) │   │          tool-calling  │   │ outbox (SQLite)      │
└──────────────────────┘   │ offline: local matcher │   └──────────────────────┘
                           │          over registry │              │
                           └────────────────────────┘              ▼
┌── Discovery ─────────────────────────────────────┐    ┌── Backend ───────────┐
│ GET /v3/api-docs → parse OpenAPI 3.1 → registry  │───▶│ generated Spring Boot│
│ → SQLite cache (authority when offline)          │    └──────────────────────┘
└──────────────────────────────────────────────────┘
```

| Stage | What it is | Decision it carries |
|---|---|---|
| Voice | `sherpa_onnx` speech-to-text running fully on device, and the platform TTS engine | STT is the embedded recognizer; the platform recognizer is not used. TTS is platform, locale `es-US`, pinned to a voice with `network_required: 0`. Audio is 16 kHz mono. |
| Resolution | Turns a transcript into one operation plus its bound values | Online: an LLM offered the registry as a dynamically built tool set, called through the UMLive proxy — no provider key ever reaches the device (`FR-MC01`, `FR-MC01b`). Offline: a deterministic matcher over the cached registry, no model (`FR-MC04`). |
| Execution | Performs the operation and owns durability | One HTTP client carrying the shared bearer token; every write not acknowledged by the backend is persisted to the outbox before the user is told anything. |
| Discovery | Builds the registry from the backend's published description | `GET /v3/api-docs`, parse OpenAPI 3.1, derive one operation per path × method, persist to SQLite. The cached registry is the authority when offline (`FR-MA02`–`FR-MA04`). |

**The registry is the spine.** Both resolvers read the same derived structure:
the online one projects it into tool schemas, the offline one matches against it
directly. Build it once and well. Nothing downstream may invent a path, verb or
field name that the registry does not contain.

## 3. Folder layout under `lib/`

| Folder | Responsibility |
|---|---|
| `theme/` | Design tokens and the Material theme built from them. No screen names a colour, radius or text size directly. |
| `l10n/` | `app_es.arb` and the generated `AppLocalizations`. Every user-facing string, and nothing else, lives here. |
| `core/` | Cross-cutting primitives: result types, clock, logging. No feature logic. |
| `data/` | sqflite database, row models, and the repositories that own every read and write of local state. |
| `openapi/` | OpenAPI document parsing and the document-to-registry derivation. |
| `net/` | HTTP client, discovery fetch, and reachability decisions. |
| `voice/` | STT, TTS, model provisioning and extraction, microphone amplitude. |
| `resolve/` | Online resolver, offline resolver, slot filling, confirmation, and registry-to-tools projection. |
| `exec/` | Operation executor, error-to-sentence mapping, outbox drain. |
| `presentation/` | Screens, widgets, turn models. It renders state; it never talks to the network or the database directly. |

## 4. The five outcomes of a turn

Every utterance resolves into exactly one of these, and they are never
conflated — different copy, different treatment, and distinguishable without
colour (`PRD-MOBILE-ux-spec.md`, Pass 1 and Pass 3):

| Outcome | Meaning |
|---|---|
| **done** | The backend answered. This is the only outcome that may render a result card. |
| **queued** | The command was persisted and will be sent later. Carries the same visual mark everywhere it appears. |
| **not understood** | The utterance could not be resolved. It says what was not understood; it never guesses. |
| **asking for a field** | Slot filling: exactly one missing required field is requested, in schema order, and nothing competes with the question. |
| **confirming** | A write is read back in domain language and waits for an affirmative. Reads never ask. |

An acknowledgement is never rendered as a result. The moment queued action
anywhere looks like done, the app is lying about durability.

## 5. SQLite schema (sqflite)

Four tables, and this is the whole of it. Later tasks extend this section before
they extend the database.

```sql
CREATE TABLE profile(
  id                TEXT PRIMARY KEY,
  base_url          TEXT NOT NULL,
  label             TEXT,
  created_at        INTEGER NOT NULL,
  last_connected_at INTEGER
);

CREATE TABLE registry(
  profile_id       TEXT PRIMARY KEY,
  document_hash    TEXT NOT NULL,
  document_json    TEXT NOT NULL,
  derived_json     TEXT NOT NULL,
  openapi_version  TEXT,
  fetched_at       INTEGER NOT NULL
);

CREATE TABLE outbox(
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id      TEXT NOT NULL,
  seq             INTEGER NOT NULL,
  operation_id    TEXT NOT NULL,
  method          TEXT NOT NULL,
  path            TEXT NOT NULL,
  path_params_json TEXT,
  body_json       TEXT,
  idempotency_key TEXT,
  created_at      INTEGER NOT NULL,
  status          TEXT NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  kind            TEXT NOT NULL
);

CREATE TABLE read_cache(
  profile_id    TEXT NOT NULL,
  operation_key TEXT NOT NULL,
  fetched_at    INTEGER NOT NULL,
  response_json TEXT NOT NULL,
  PRIMARY KEY(profile_id, operation_key)
);
```

- The **base URL and the shared bearer token live in `flutter_secure_storage`**,
  never in SQLite. `profile` holds only the identifier, the non-secret label and
  timestamps.
- `registry.derived_json` holds the derived registry as JSON. The offline
  resolver matches it in memory, which is correct at demo scale (`FR-ME02`).
- `outbox.seq` is the monotonic issue order; the drain is strictly FIFO and
  stops on the first failure.
- `outbox` is written **before** any acknowledgement reaches the user
  (`FR-MD02`), and survives a force-kill (`FR-MD06`).
- `read_cache` exists so an offline read can be answered and labelled with its
  age (`FR-MD05`). Writes are never answered from cache.

## 6. Conventions

- **All code, identifiers, comments, commit messages and docs in English.**
- **All user-facing copy in Spanish through `AppLocalizations`**
  (`lib/l10n/app_es.arb`). A literal user-facing string in Dart is a defect.
- Copy is **Bolivian-neutral Spanish**: no voseo and no tuteo.
- **No test file of any kind and no test runner.** TDD is off for this
  repository; do not introduce a runner without asking.
- **One work-unit commit per task**, Conventional Commit message, no attribution
  lines. Tests and docs that belong to a change ship in the same commit.
- Discipline: no hard-coded route, verb or field name; no new dependency without
  an explicit decision; no behaviour the PRD does not specify.

## 7. Verification protocol

In this order, every times:

1. `cd apps/mobile && flutter analyze` — must be clean.
2. `cd apps/mobile && flutter build apk --debug --target-platform android-arm64`.
   The `--target-platform` flag is the only mechanism that actually restricts
   ABIs: Flutter's Gradle plugin clears `ndk.abiFilters`, so filters in Gradle
   are not the control. Verified.
3. `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, then exercise
   the behaviour on the physical handset. A build that analyzes clean is not
   evidence; the handset is.
4. **Any offline claim** requires disabling Wi-Fi **and** mobile data explicitly
   and confirming `Network is unreachable` *before* the test. Airplane mode on
   this handset leaves Wi-Fi up, so airplane mode alone proves nothing.

`adb` lives at `C:/Users/lTemp/AppData/Local/Android/Sdk/platform-tools/adb.exe`.
Git Bash needs `MSYS_NO_PATHCONV=1` for device-side paths (`/sdcard/...`), which
then requires a `C:/…` Windows path for the local side of the same command.

## 8. Device

| | |
|---|---|
| Model | HONOR TFY-LX3 |
| Android | 13 (API 33), MagicOS 7.1.0.284 |
| ABI | `arm64-v8a` |
| Screen | 1080 × 2388 physical, device pixel ratio 2.75 |

`minSdk` is 23 and only `arm64-v8a` is built.

## 9. Proving a rendered colour

`adb exec-out screencap -p` returns true pixel values, so a rendered colour can
be checked numerically against its token instead of eyeballed. Decode the PNG
and read the pixels:

```bash
adb exec-out screencap -p > tmp/shots/shot.png
ffmpeg -v error -i tmp/shots/shot.png -f rawvideo -pix_fmt rgba - \
  | node -e 'let c=[];process.stdin.on("data",d=>c.push(d)).on("end",()=>{const b=Buffer.concat(c),w=1080;const o=(420*w+540)*4;console.log("#"+b.slice(o,o+3).toString("hex"));});'
```

Use this whenever a visual claim has to be proven rather than described. Read
the physical device pixel size (1080 × 2388) to compute row offsets, not the
logical size. Capture into the git-ignored `tmp/shots/`, never into a tracked
path.
