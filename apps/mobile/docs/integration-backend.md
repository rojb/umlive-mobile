# A real generated backend to verify the app against

`tmp/mobile-fixture/backend/` is a **genuinely generated** Spring Boot project: the
UMLive codegen emitters produced it. The app under `apps/mobile` can be pointed at it
and will find a real `/v3/api-docs`, exactly as with any user-generated backend.

## What the fixture is

`apps/api/scripts/mobile-fixture-backend.ts` is a **plain script run by hand** — not a
runner, not a test, not wired to a pipeline. It builds a `DiagramContent` of nine
classes in memory (`Cliente` with a mandatory `nombre` and an optional `email`, plus
`Cita`, `Producto`, `Pedido`, `Dirección`, `Empleado`, `Categoria`, `Pago`,
`ItemPedido`) with three associations, one of them a collection, and drives the
shipped pure functions `buildIr`, `emitProject` and `buildZip` directly.

```bash
cd apps/api
npx tsx scripts/mobile-fixture-backend.ts   # writes tmp/mobile-fixture/
```

(`packages/contracts` must already be built.) The run is idempotent: it deletes and
rewrites `tmp/mobile-fixture/backend.zip` and `tmp/mobile-fixture/backend/` every
time. `Dirección` is there on purpose — its route is folded to ASCII, so its
controller is `/api/direccion` and the run prints the `route_ascii_folded` note. The
same run prints the operation inventory and the `ClienteRequest` components.

## Start, stop, reach it from the handset

```bash
cd tmp/mobile-fixture/backend
docker compose up -d          # PostgreSQL 17 on host port 15432
./mvnw spring-boot:run        # http://127.0.0.1:8080

# Stop. The forked JVM survives killing the wrapper and keeps holding 8080,
# so kill by listening port, never by process name.
netstat -ano | grep LISTENING | grep :8080   # last column is the PID
powershell -NoProfile -Command "Stop-Process -Id <PID> -Force"
docker compose down                          # from tmp/mobile-fixture/backend

# Reach it from the handset over USB: no tunnel, no LAN.
ADB="C:/Users/lTemp/AppData/Local/Android/Sdk/platform-tools/adb.exe"
"$ADB" reverse tcp:8080 tcp:8080
"$ADB" reverse --list          # expect: UsbFfs tcp:8080 tcp:8080
```

`mvnw` downloads Maven 3.9.14 on first use. The JDK on `PATH` (25) compiles the pom's
`release 21`; no JDK 17 is installed here and none is needed. Re-run `adb reverse`
after every re-plug or reboot. The phone then reaches the backend at
**`http://127.0.0.1:8080`** — the base URL the app must be pointed at.

## Endpoint inventory

`/v3/api-docs` publishes 18 paths / 45 operations: each of `cliente`, `cita`,
`producto`, `pedido`, `direccion`, `empleado`, `categoria`, `pago` and `item-pedido`
exposes the same five verbs under `/api/<route>` — `GET`, `GET /{id}`, `POST`,
`PUT /{id}`, `DELETE /{id}` — with no extras.

The truthful obligation slot filling depends on: the live `POST /api/cliente` request
body's `required` array is exactly `["nombre"]`; `email` is absent.

## Honest limits

- The **real emitters**, not the platform: `DiagramContentService` (Prisma and the
  `RepeatableRead` snapshot) and `ValidationService` are bypassed — the report is
  hand-built empty and non-blocking, so no blocking finding is ever rendered.
- A **hand-run script**, not a runner: no CI, no assertions, no exit-code contract.
- The shared-secret guard is emitted but **off** (`umlive.security.shared-token`
  empty), so every `/api/**` route answers unauthenticated.
- No seed data: `GET /api/cliente` answers `[]` until the app writes. PostgreSQL has
  no named volume, so `docker compose down` then `up -d` starts empty and Flyway
  re-applies the schema on every start.
