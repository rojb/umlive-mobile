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
│ sherpa STT (offline) │──▶│ deterministic matcher  │──▶│ HTTP client + token  │
│ platform TTS (es-US) │   │ over the registry      │   │ outbox (SQLite)      │
└──────────────────────┘   │ no model (FR-MC04)     │   └──────────────────────┘
                           └────────────────────────┘              ▼
┌── Discovery ─────────────────────────────────────┐    ┌── Backend ───────────┐
│ GET /v3/api-docs → parse OpenAPI 3.1 → registry  │───▶│ generated Spring Boot│
│ → SQLite cache (authority when offline)          │    └──────────────────────┘
└──────────────────────────────────────────────────┘
```

| Stage | What it is | Decision it carries |
|---|---|---|
| Voice | `sherpa_onnx` speech-to-text running fully on device, and the platform TTS engine | STT is the embedded recognizer; the platform recognizer is not used. TTS is platform, locale `es-US`, pinned to a voice with `network_required: 0`. Audio is 16 kHz mono. |
| Resolution | Turns a transcript into one operation plus its bound values | One deterministic matcher over the registry, no model, used identically with and without network (`FR-MC04`). There is no online branch: `T9`/`T10` were cancelled and the app never calls a model. |
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
| `conversation/` | The turn model, the deterministic resolver — the read path in `T12`, slot filling and confirmation in `T13` — the Spanish input vocabulary, and the operation executor. There is no `resolve/` and no `exec/`: `T11` built the loop in one folder and later tasks extend it there. Error-to-sentence mapping and the outbox drain land in `T22`/`T14`. |
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

In this order, every time:

0. `cd apps/mobile && ./tool/fetch_sherpa_model.sh` — **the one hand-run
   prerequisite of a fresh clone.** The offline recognition model is about
   126 MB on disk and is deliberately not committed, while `pubspec.yaml`
   declares both of its files as assets: a build that skips this step fails
   loudly instead of shipping an app that cannot hear. The script downloads the
   archive, verifies it against the recorded SHA-256, verifies both extracted
   files against their recorded identities, and writes them into the git-ignored
   `assets/models/sherpa-es/`. It is idempotent, `--force` re-does it, and
   `--print-identity` prints the block that `lib/voice/voice_assets.dart`
   carries, so the script and the app cannot disagree about what the model is.
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

**The USB mapping is not isolation.** `adb reverse tcp:8080 tcp:8080` makes the
host's backend answer at `127.0.0.1:8080` *on the handset itself*, over the USB
cable, so turning every radio off does not break it: the app stays connected and
an offline test run that way proves the opposite of what it claims. A genuine
offline test therefore has to `adb reverse --remove tcp:8080` **and** disable
Wi-Fi and mobile data, and it must see `ping` answer `Network is unreachable`
from the device **before** the result is believed. Airplane mode is not
isolation on this handset, and neither is the radio switch on its own while the
reverse mapping is up. The same care applies in reverse when restoring: re-enable
Wi-Fi and data, re-run `adb reverse tcp:8080 tcp:8080`, and confirm the mapping
with `adb reverse --list` before claiming the online state again.

`adb` lives at `C:/Users/lTemp/AppData/Local/Android/Sdk/platform-tools/adb.exe`.
Git Bash needs `MSYS_NO_PATHCONV=1` for device-side paths (`/sdcard/...`), which
then requires a `C:/…` Windows path for the local side of the same command.

**Known environment quirk.** On this Windows host the Kotlin incremental
compile cache of a plugin under `build/` can end up locked, and Gradle then
fails with `Could not close incremental caches … caches-jvm`. The build itself
is fine; the workaround is to pass the property through to Gradle, which Flutter
supports:

```bash
flutter build apk --debug --target-platform android-arm64 \
  -P kotlin.incremental=false
```

**Verifying the offline voice path.** Recognition cannot be read from a
screenshot, so the app logs everything that has to be believed under
`[umlive][stt]` and `[umlive][tts]`, and a build made with
`-D UMLIVE_VOICE_SELFCHECK=true` runs the whole offline chain on launch:
provision, build the recognizer, synthesise the `§5.1` utterance to a WAV file
with the platform engine, decode that same file through the recognizer, speak
it, and finish with a five-second microphone window. That build also opens the
diagnostics screen instead of the assistant, so the same run can be watched;
the screen is registered as a route **only** with that flag, so no tap in an
ordinary build reaches it. `adb logcat -d | grep umlive` is the evidence.

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

## 10. State and services

`lib/app/` is the composition root. It holds no feature of its own. T2 fixes
this shape; later tasks extend it instead of inventing a parallel one.

- `AppServices.bootstrap()` is called once, in `main()`, before the first frame.
  It opens the database, builds the repositories and the controller, and
  restores the stored profile. It is the only place that constructs them.
- `AppScope` is an `InheritedWidget`; screens read dependencies with
  `AppScope.of(context)`. No state-management package: `ChangeNotifier` plus
  `ListenableBuilder` only.
- `ConnectionController extends ChangeNotifier` (in `presentation/`) owns the
  address, the profile id, the in-flight probe and the reachability state of
  `FR-MA05`. It is the single owner of connection state; no screen probes.
- Repositories are the only objects that touch `sqflite` or
  `flutter_secure_storage`: `ProfileRepository` (the address and token as
  secrets, the `profile` row) and `RegistryRepository` (the `registry` table;
  T4 fills it).
- `net/` holds the pure decisions — `BackendAddressParser` (normalization) and
  `TransportPolicy` (cleartext allowed only for loopback and private ranges) —
  and the impure `BackendProbe`, which is the only object that issues a request
  before T3.
- `core/log.dart` writes `[umlive][<area>] key=value` lines to `debugPrint`, so
  `adb logcat -d | grep umlive` proves a transition without a screenshot.
- `profile.base_url` is created by the fixed DDL but stays empty: the address
  lives in `flutter_secure_storage`, never in SQLite (§5).

## 11. The derived registry (T3)

`lib/openapi/` owns the document-to-registry derivation; `lib/core/sha256.dart`
owns the document hash. T4 persists, T5 reports failure, the resolvers read.

- **Identity is the operation key**, `"<METHOD> <path template>"` — never
  `operationId`. springdoc deduplicates `operationId` with an unstable numeric
  suffix (`create_6`), so it is carried for `FR-MA03` and treated as evidence.
- **Entities are derived, never listed.** The collection route is the path with
  its trailing `{parameter}` segments removed; operations group by it and take
  their role from the verb plus whether the path carries parameters. Nothing
  knows the word `cliente`.
- **The un-folded domain name is recovered from the schema `$ref`.** The
  generator folds routes to ASCII but leaves schema names in their original UML
  spelling, so `DirecciónRequest`/`DirecciónResponse` fold to the route word
  `direccion` and confirm the spoken name `Dirección` (`FR-MC07`). No generator
  extension is emitted, and none is looked for.
- **Field order is schema order.** `readableFields` and
  `requiredWritableFields` follow the property declaration order of their
  schema; `SchemaDescriptor.required` preserves the document's `required` array
  in its declared order. `requiredWritableFields` is the required subset of the
  create request schema, falling back to update — that list is what slot filling
  (`FR-MC02`) walks.
- **Response bodies live under every declared content type.** The generated
  backend answers under `*/*` and accepts `application/json`, so the parser
  scans content types instead of assuming one.
- **Parsing is tolerant and never silent.** An unknown verb, an unresolved
  `$ref`, an unsupported composition, a path with no operations, a `required`
  name with no property: each becomes a `RegistryDiagnostic`. A document with no
  paths is **not** an error — the backend exposes no operations and Pass 6 gives
  that its own sentence.
- **Discovery is wired into the probe.** `BackendProbe` reads the 2xx body,
  `ConnectionController` parses it and exposes `apiRegistry`; the controller logs
  one `[umlive][registry] kind=operation` line per operation, one `kind=entity`
  line per entity, one `kind=document` line with the SHA-256, and the
  `kind=summary` line — the KR2 evidence. `servers[0].url` is derived from the
  request host, so it is never used as a base URL.

## 12. The registry cache and explicit discovery failure (T4, T5)

- **One row per profile, written on every successful discovery.**
  `registry.document_hash`, `document_json` (the raw document),
  `derived_json` (`ApiRegistry.toJson`, decoded by `ApiRegistry.fromJson`),
  `openapi_version` and `fetched_at`. The model round-trips through JSON, and
  the cache is the authority when the backend does not answer (`FR-MA04`).
- **The cache is loaded on cold start, before the first probe.**
  `ConnectionController.loadStoredProfile()` reads the row, so the first frame
  already has a registry to work with and an offline launch lists the same
  entities as the last connect. It logs `kind=cache result=loaded` plus one
  `kind=entity source=cache` line per entity.
- **A document the parser did not accept never overwrites a good row.**
  Persistence is reached only from an accepted OpenAPI 3.x description
  (`RegistryParseResult.isOpenApiDocument`), so an HTML page, a stray JSON body
  or a truncated read leaves the stored registry untouched. This rule is stated
  in the controller and in the repository, because both are places a later task
  might otherwise relax it.
- **Change detection is by document hash** (`FR-MA07`). An identical hash
  rewrites nothing and shows nothing. A different hash re-derives, persists and
  reports the operations added and removed, as
  `[umlive][registry] kind=change added=… removed=…` and on the Connect screen —
  hidden until it happens, Primary when it does. Identity is the operation key
  (`"<METHOD> <path>"`), never `operationId`, for the same reason the registry
  keys on it.
- **Changing the address drops the cached registry.** The `profile` row is
  reused across an address change, so a row left behind would make the app claim
  `offlineWithCache` about a backend it has never reached.
- **Discovery failure is explicit and never guesses** (`FR-MA06`). The
  reachability enum carries the state per cause: `missingDescription` (404 — the
  backend was generated without `springdoc-openapi`), `notAnApiDescription`
  (2xx whose body is not an OpenAPI document, e.g. HTML at that path), and
  `offlineWithCache`/`unreachable` for no answer at all. The Connect screen's
  *Partial* state names the cause and offers retry or change address; an empty
  description (no operations) says the backend exposes no operations and offers
  no way into a conversation that could only fail. There is no code path that
  synthesises a route from an entity name: every path, verb and field the app
  uses comes from the registry, which comes from the document.

## 13. Voice: embedded recognition, platform synthesis (T6, T7)

The product rests on both halves working with every radio off, so both are
stated here as decisions with the evidence that chose them. Folder roles are
`lib/voice/` (engine) and `lib/presentation/` (rendering); the composition root
is unchanged: `AppServices` builds one `VoiceController`, `main()` calls
`voice.initialize()` after the first frame (provisioning 126 MB must not hold up
startup), and screens listen to it like they listen to `ConnectionController`.

### 13.1 The model is bundled, provisioned at first run, and never committed

- `sherpa_onnx` 1.13.8 (federated package; the per-ABI alternatives are
  deliberately not added), `record` 7.1.1, `path_provider` 2.1.6.
- The model is `sherpa-onnx-nemo-fast-conformer-ctc-es-1424-int8`: archive
  SHA-256 `75053ea480a95eb9df7831cf085e016dbde34fb99d017a85faec964bef395b6f`,
  `model.int8.onnx` at 131 652 445 bytes and `tokens.txt` at 10 871 bytes.
- **The 126 MB blob is not in git.** `/assets/models/sherpa-es/*` is ignored and
  `tool/fetch_sherpa_model.sh` is the one hand-run prerequisite (protocol §7,
  step 0). It downloads the archive, verifies it and both extracted files
  against the recorded identities, and only then writes them into
  `assets/models/sherpa-es/`. `--force` re-does it; `--print-identity` prints the
  block `lib/voice/voice_assets.dart` carries, so the script and the app cannot
  disagree about what the model is. `pubspec.yaml` declares the two files
  individually, so a clone that skipped the script fails at build time.
- Provisioning copies the model out of the APK into `<app files>/sherpa-es/` at
  first run, **streamed by a Kotlin method channel** (`MainActivity`, channel
  `com.umlive.voice/assets`, `AssetManager` → file in 1 MiB chunks with progress
  callbacks). `rootBundle.load` was rejected because it materialises the whole
  126 MB in the Dart heap; the channel's peak is one chunk plus the digest. The
  channel reports the SHA-256 of what it wrote and the Dart side refuses
  anything that does not match; the resolved asset key is logged, which is what
  makes the bundle layout verifiable. Provisioning is idempotent: a marker plus
  both file sizes short-circuit a repeat run.
- The app never degrades silently (`FR-MB01c`, `FR-MB03`). While provisioning
  runs, and whenever it fails, the readiness banner on the Assistant screen
  states that offline voice is unavailable and names the cause: asset missing
  from the build, identity mismatch, copy failure, or recognizer failure.
  Synthesis unavailability is stated separately, because the two halves are
  selected independently (`FR-MB02`).

### 13.2 Recognition: the measured configuration, copied and not re-derived

- Built in a dedicated isolate (`lib/voice/sherpa_recognizer.dart`) that calls
  `initBindings()` **again**: the bindings are per isolate, and this isolate is
  a second one. `numThreads: 2`, `decodingMethod: 'greedy_search'`, 16 kHz,
  feature dim 80. Keeping it off the UI isolate is not cosmetic — construction
  is seconds of native work and every decode is CPU-bound.
- Capture: `record` with `AudioEncoder.pcm16bits`, 16 kHz mono; int16 little
  endian → Float32 `[-1, 1]` via `getInt16(i * 2, Endian.little) / 32768.0`.
- `lib/voice/wav_audio.dart` reads PCM WAV for one reason: to decode audio the
  microphone did not produce. The platform synthesizer writes 24 kHz mono here,
  and the reader resamples to 16 kHz, which is how recognition is *observed*
  with the radios off without a human speaking into the handset. The source
  rate, channel count and the fact that resampling happened are logged.
- Partials are re-decodes of the audio captured so far (`FR-MB05`): the first
  after ~1.2 s, then at most one every ~1.5 s, and a tick is **skipped** while a
  previous decode is still running so work never piles up behind a slow decode.
  The microphone window is capped at 45 s of audio, which is longer than any
  single `§5.1` utterance and bounded on purpose.
- The transcript renders the last completed partial in `text-primary` and a
  muted in-flight marker in `text-muted` (`lib/presentation/widgets/
  live_transcript_view.dart`). That is the UX spec's "confirmed words white,
  in-flight tail muted" adapted to a **non-streaming** engine, which exposes no
  confirmed-prefix boundary: the last completed partial is real text the
  recognizer produced, and the audio no decode has looked at yet gets a muted
  marker rather than muted words, because words for undecoded audio would be
  invented.
- The verification surface is the log, not the screen. `[umlive][stt]` carries
  provisioning bytes and hashes, `model_load` ms and bytes, recognizer
  construction ms with `init_bindings_ms`, threads and decoding method, and for
  every decode `source`, `sample_rate`, `audio_ms`, `decode_ms`, `rtf` and the
  recognised `text`.

### 13.3 Synthesis: platform engine, pinned to an offline voice

- `flutter_tts` `^4.2.5`, `com.google.android.tts`, locale `es-US`.
- The voice is chosen from `getVoices` — Spanish **and** `network_required: 0` —
  and pinned with `setVoice`, never with `setLanguage` alone: half the `es-US`
  catalogue needs the network and `setLanguage` leaves the engine free to take
  one of those. `es-US` is preferred, then another offline Spanish locale, and
  the fallback is logged (`fallback_locale=true`) rather than hidden.
- Availability is decided from `getVoices`/`getLanguages`, never from
  `isLanguageAvailable`, which is optimistic on this handset (measured: `true`
  for `es-BO`, `es-419` and `es-MX` while the catalogue holds only `es-ES` and
  `es-US`). No offline Spanish voice means a visible sentence and a refusal: no
  network voice is ever substituted, and no preference-style offline hint is
  relied on (`FR-MB01`).
- Offline synthesis is evidenced by file rather than by ear:
  `synthesizeToFile` writes into the app's cache directory and
  `[umlive][tts] kind=synthesize` carries the path, the byte size and the pinned
  voice's `name`, `locale` and `network_required`.

### 13.4 Models considered and not adopted

Recorded so the choice is a decision rather than a default. Both are Spanish and
both exist in the same `sherpa-onnx` asr-models release:

| Model | Size | Why not now |
|---|---|---|
| `sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06` | 118.6 MB | Streaming, so it would give real partials instead of re-decodes. Unmeasured on this handset, while the non-streaming model already decodes well below real time. This is the recorded fallback if partial latency becomes the problem. |
| `sherpa-onnx-moonshine-base-es-quantized-2026-02-27` | 48.5 MB | Much smaller, but a different model family, unmeasured here, and accuracy on the `§5.1` utterances is the only thing that matters — it has not been demonstrated. |

`speech_to_text` is deliberately **not** a dependency: the platform recognizer
failed hard with `error_language_unavailable` on this handset with the radios on
*and* off, and does not fall back because its availability flag reports `true`
(`PRD-MOBILE.md` §10.2).

## 14. Resolution: one deterministic resolver over the registry (T12)

`FR-MC04` was rewritten on 2026-09-20: the local matcher is not the offline
branch of two, it is *the* resolver. There is no model in this product and no
online branch to fall back on, so `T9`/`T10` stay cancelled and this is the only
path an utterance takes.

- **`lib/conversation/deterministic_resolver.dart` is that path.**
  `ConversationController` hands it one utterance, the registry, the executor
  and the localizations; it returns one `ResolverOutcome` and reaches nothing
  else. It is stateless, so nothing leaks between turns, and it is the shipped
  default of `ConversationController.resolver`.
- **Folding has exactly one definition.** `lib/core/text_fold.dart` holds
  `foldText` — lower-case, accents folded to ASCII — and both the parser (§11,
  recovering `Dirección` from the ASCII route word `direccion`) and the resolver
  call it. A second copy would let the parser confirm a name the resolver can
  never match, which surfaces as a silently unresolved utterance.
- **Matching is on whole folded tokens.** Every contiguous window of the
  utterance is joined with no separator and compared against the entity's folded
  name and its `s`/`es`/`ces` plurals, so `clientela` never matches `cliente`
  while the two spoken words "item pedido" still name `ItemPedido`. Tokens,
  trigger words, fillers and the noun plural live in
  `lib/conversation/spanish_language.dart` — the one file that holds Spanish
  *input* vocabulary and morphology. It is not copy: nothing in it is rendered,
  which is why it is not in `app_es.arb`.
- **Intent is classified before anything is called.** A count trigger (the
  `cuántos` family) is a count; a numeric token is a single-record read *only*
  if the entity publishes a `get` role; a list trigger (`lista`, `mostrar`,
  `dame`, `todos`…) or an utterance made only of fillers and the entity's own
  name is a listing. Everything else is **not understood** — which is why the
  §5.1 write utterance *"Agregá a Juan Pérez como cliente"* reports that it was
  not understood instead of answering a create with a listing. The write path is
  `T13`.
- **A numeric token never degrades into a listing.** With no `get` role, "cliente
  3" is not understood, because answering with the whole collection would drop
  the filter the operator asked for and present that as the answer.
- **Operations come from roles, never from an assembled URL** (`FR-MA03`):
  `EntityModel.roleKeys[EntityRole.list]` or `[EntityRole.get]`, looked up with
  `ApiRegistry.operation`, with the id bound to
  `ApiOperation.pathParameterNames.first`. A missing role, or a `get` operation
  that declares no path parameter, is refused rather than patched with a guessed
  route or parameter name.
- **The count is computed client-side** from the full collection the backend
  returned (`FR-ME02`): the generated API publishes no count endpoint and no
  pagination.
- **Every failed resolution names what it could not resolve** (`FR-MC04`): no
  known entity named — and the refusal lists the vocabulary the registry *does*
  have (`FR-MC07`) — more than one entity named, an intent that was not
  understood, or a read the backend does not publish. Ambiguity is decided by
  window position as well as score: a match overlapping the best window is
  another reading of the same mention, one that sits elsewhere is a second
  mention the operator actually made. It never guesses.
- **The answer is one sentence with correct agreement.** The zero form is the UX
  spec's empty-collection sentence, the singular form names the count with the
  singular noun because `FR-ME01` calls that case a test case, and the plural
  form carries the count. The register is impersonal — no tuteo, no voseo — per
  the app's copy convention, so §5.1's *"Tienes 1 cliente."* is stated as *"Hay 1
  cliente."*. `pluralizeSpanishNoun` covers the `-ión` family that drops its
  written accent (`dirección` → `direcciones`); it is a morphology rule, not a
  dictionary, and its remaining limits are stated in the file. Rendering a
  collection as cards is `T21`; `T12` answers with the sentence and the addressed
  operation only.
- **Every resolve logs one `[umlive][resolver]` line** with `result`, `intent`,
  `entity`, `operation` and `count`/`reason`, and **never the utterance text** —
  only its length, the discipline `T11` established. Eleven turns exercised on
  `TFY-LX3` make up the evidence, and the log line and the written reply agreed
  on every one of them.
