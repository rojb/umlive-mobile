# The §5.1 acceptance walkthrough

`PRD-MOBILE.md` §5.1 names four utterances as **contractual behaviour**, and this
document is the script that exercises them end to end — online, and again with the
radios off — plus the evidence from the run that closed `T25`.

It is a hand-run script, not a test suite: this repository has no test runner on
purpose (`docs/architecture.md` §6), and a microphone cannot be asserted from a
unit test.

## Preconditions

| | |
|---|---|
| Backend | the generated fixture on `http://127.0.0.1:8080`, reached from the handset with `adb reverse tcp:8080 tcp:8080` |
| App | `flutter build apk --debug --target-platform android-arm64 -P kotlin.incremental=false`, installed with `adb install -r` |
| Schema under test | `cliente` requires `nombre` (optional `email`); `direccion` requires `calle` and `ciudad` (optional `códigoPostal`) |
| Reading the evidence | `adb logcat -d -v time \| grep umlive` for the log, `uiautomator dump` for what is on screen — Flutter puts its strings in `content-desc`, and only the `EditText` carries `text=` |
| Offline means | `adb reverse --remove tcp:8080` **plus** `svc wifi disable` and `svc data disable`, with `ping -c 2 8.8.8.8` answering *Network is unreachable*. Airplane mode alone does not isolate this handset |

## Pass A — online

| # | Utterance | Expected | Observed |
|---|---|---|---|
| 3a | *Listá todos los clientes* | `GET` on the collection, rendered as domain cards, never as JSON | `Hay 1 cliente.` with one card; `[umlive][executor] operation=GET_/api/cliente … status=200`; `[umlive][resolver] result=read intent=list … count=1` |
| 1 | *Agregá a Juan Pérez como cliente* | the name is captured from the utterance, the assistant determines from the schema that `Cliente` requires **no further** field, and reads the complete record back before writing anything | the band went straight to the read-back — `Se va a crear este registro de cliente:` / `Datos capturados` / `nombre: Juan Perez`; `… phase=confirming extracted=true`; **no executor line** |
| 2 | *(confirming)* | the `POST` is issued only after the affirmative, and the result is stated | `POST_/api/cliente … status=201`, `Listo: se creó el registro de cliente.`, record `id=12` |
| 2 | *Agregá una direccion* → *Av. Siempreviva 742* → *Springfield* | **exactly one missing required field is asked at a time, in schema order**, then the read-back | `Falta un campo obligatorio: calle.` → `Falta un campo obligatorio: ciudad.` (with the draft under it) → the read-back with both values → `201`, `direccion id=8` |
| 3b | *Listá todos los clientes* | the collection **includes the record created in step 2** (`FR-ME04`) | `Hay 2 clientes.` with `2 registros de clientes.` and card 2 of 2 carrying `id 12` |
| 4 | *¿Cuántos clientes tengo?* | a count with correct agreement, computed client-side | `Hay 2 clientes.`, `intent=count … count=2` |

**The one wording delta, stated where the contract is read.** §5.1's form is
*"Tienes 1 cliente."*. The app says *"Hay 2 clientes."*: the count and the agreement
the requirement names are both there, and the second person is not, because the copy
convention is impersonal — the decision `docs/architecture.md` §14 records, taken
with the product owner and applied consistently since `T11`. The count is 2 because
the fixture already held a client before the run; the app's answer is correct for the
data present.

**On step 1's shape.** §5.1 describes a diagram whose `Cliente` requires fields
beyond the name. Against this fixture `nombre` is the only required field, so the
honest observation is *zero questions, one read-back*: the rule is "ask exactly one
missing required field at a time, in schema order", and zero are missing here. The
rule itself is exercised with real questions in the `direccion` loop, where `calle`
is asked before `ciudad` and never both at once.

## Pass B — radios off

| # | Utterance | Expected (§6.D) | Observed |
|---|---|---|---|
| 3 | *Listá todos los clientes* | answered from the remembered collection, **labelled with its age** | `Hay 2 clientes. Datos guardados hace instantes.`; `[umlive][cache] action=hit … age_ms=45771`; `cache=true` |
| 1–2 | *Agregá a Juan Pérez como cliente* → confirm | acknowledged aloud, **persisted before the acknowledgement**, never reported as done | `action=spoke kind=cue`, `POST … result=network_error`, `[umlive][outbox] action=enqueue id=11 seq=1 kind=create`, `reason=queued`, `status=queued`, *"Quedó en cola: el registro de cliente se enviará cuando el backend vuelva a responder."*, no executor success |
| 4 | *¿Cuántos clientes tengo?* | the remembered count with its age | `Hay 2 clientes. Datos guardados hace 1 minuto.`, `count=2 cache=true` |
| — | radios back | the queue drains **by itself**, in order, with the replayed create carrying its key | `drain step=start count=1` → `POST_/api/cliente … status=201 … replay=true` → `step=sent seq=1 status=201` → `step=stop reason=done remaining=0`; record `id=13`; *"Se envió el alta pendiente de cliente."* |

Step 2's offline contract is the same command as step 1 (the create), so one run of
it covers both; nothing was invented to give it a row of its own.

## What the run left in place

The three records the walkthrough created (`cliente 12`, `cliente 13`,
`direccion 8`) were deleted afterwards with the backend's own `DELETE`, and the
collections were verified equal to their starting state. Deleting them through the
app's voice path is also possible (`Borra el cliente 12`) and is covered by `T13b`'s
own verification; the walkthrough keeps the clean-up mechanical so the next run
starts from the same place.

## Reproducing it

1. Start the fixture backend and map it to the handset (`adb reverse tcp:8080 tcp:8080`).
2. Build and install the debug APK; wait for `Conectado`.
3. Run Pass A's utterances in order, reading the reply from a `uiautomator` dump and the operation from the log.
4. Remove the mapping and both radios, confirm `ping` says *Network is unreachable*, and run Pass B.
5. Restore the radios and the mapping, and watch the queue drain without touching the app.
6. Delete whatever the run created and confirm the collections are back to their starting state.
