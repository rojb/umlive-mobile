#!/usr/bin/env bash
#
# Fetches the offline recognition model and puts it where the build expects it.
#
# The model is 126 MB on disk, so it is NOT committed to git. This script is the
# one hand-run prerequisite of a fresh clone:
#
#   apps/mobile/tool/fetch_sherpa_model.sh
#
# It downloads
#   sherpa-onnx-nemo-fast-conformer-ctc-es-1424-int8.tar.bz2
# from the sherpa-onnx asr-models release, verifies the archive against the
# recorded SHA-256 below, and extracts the only two files the recognizer reads
# into assets/models/sherpa-es/ (git-ignored):
#
#   model.int8.onnx   the acoustic model
#   tokens.txt        its token table
#
# The same identity is recorded in lib/voice/voice_assets.dart, which is what the
# app verifies after copying the model out of the APK at first run. `--print-
# identity` prints that Dart block from the real files, so the two cannot drift.
#
#   --print-identity   download if needed, then print the Dart constants block
#   --force            ignore the cached archive and the existing extraction
#
# The model is the measured one: it transcribes Spanish on the demo handset with
# every radio off. The streaming zipformer and quantized moonshine Spanish models
# in the same release are recorded in docs/architecture.md §13 as the fallback,
# and are deliberately not adopted.

set -euo pipefail

ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-fast-conformer-ctc-es-1424-int8.tar.bz2"

# Recorded identity of the archive and of the two files inside it.
ARCHIVE_SHA256="75053ea480a95eb9df7831cf085e016dbde34fb99d017a85faec964bef395b6f"
MODEL_FILE="model.int8.onnx"
MODEL_BYTES=131652445
MODEL_SHA256="9539b206ba7cb46231e24eb1f1d7269370bfd45209c549d70e2bfd0e9f3b021a"
TOKENS_FILE="tokens.txt"
TOKENS_BYTES=10871
TOKENS_SHA256="6191b4853e3654f053c42f6fd184ca53b402987aefdd6ff6baa68034d803ee85"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/assets/models/sherpa-es"
CACHE="$DEST/.download"
ARCHIVE="$CACHE/$(basename "$ARCHIVE_URL")"
STAGE="$CACHE/.extract"

mode="fetch"
for arg in "$@"; do
  case "$arg" in
    --print-identity) mode="print" ;;
    --force) mode="force" ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

for tool in curl tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool" >&2
    exit 1
  }
done

sha256_of() {
  # Prints the lower-case hex digest of a file, and nothing else.
  sha256sum "$1" | cut -d' ' -f1
}

size_of() {
  # Portable byte size: stat(1) flags differ between GNU and BSD.
  wc -c <"$1" | tr -d ' '
}

download() {
  mkdir -p "$CACHE"
  if [[ -f "$ARCHIVE" && "$mode" != "force" ]]; then
    echo "using cached archive: $ARCHIVE"
    return
  fi
  echo "downloading $ARCHIVE_URL"
  echo "(98.7 MB compressed; the extracted model is about 126 MB)"
  tmp="$ARCHIVE.part"
  curl --fail --location --retry 3 --output "$tmp" "$ARCHIVE_URL"
  mv "$tmp" "$ARCHIVE"
}

verify_archive() {
  local actual
  actual="$(sha256_of "$ARCHIVE")"
  if [[ "$actual" != "$ARCHIVE_SHA256" ]]; then
    echo "archive SHA-256 mismatch" >&2
    echo "  expected $ARCHIVE_SHA256" >&2
    echo "  actual   $actual" >&2
    echo "Refusing to extract: the download is not the archive that was measured." >&2
    exit 1
  fi
  echo "archive SHA-256 verified: $actual"
}

verify_file() {
  local path="$1" expected_bytes="$2" expected_sha256="$3" label="$4"
  local actual_sha actual_bytes
  actual_sha="$(sha256_of "$path")"
  actual_bytes="$(size_of "$path")"
  if [[ "$actual_bytes" != "$expected_bytes" || "$actual_sha" != "$expected_sha256" ]]; then
    echo "$label does not match its recorded identity" >&2
    echo "  expected $expected_bytes bytes / $expected_sha256" >&2
    echo "  actual   $actual_bytes bytes / $actual_sha" >&2
    exit 1
  fi
}

extract() {
  # $1 is `yes` when the staged files must match the recorded identity. The
  # `--print-identity` run passes `no`, because that run is what discovers the
  # identity in the first place.
  local verify="$1"
  rm -rf "$STAGE"
  mkdir -p "$STAGE" "$DEST"
  # Only the two files the recognizer reads are pulled out; the archive also
  # carries a sample wav that is not wanted in the APK. `*` has to be allowed
  # to match `/`, because every member of this archive starts with `./`, and the
  # files are then located rather than assumed: --strip-components counts that
  # leading `./` as a component, which is not something to encode here.
  tar -xjf "$ARCHIVE" -C "$STAGE" --wildcards --wildcards-match-slash \
    "*/$MODEL_FILE" "*/$TOKENS_FILE"
  local staged_model staged_tokens
  staged_model="$(find "$STAGE" -type f -name "$MODEL_FILE" | head -n 1)"
  staged_tokens="$(find "$STAGE" -type f -name "$TOKENS_FILE" | head -n 1)"
  if [[ -z "$staged_model" || -z "$staged_tokens" ]]; then
    echo "archive did not contain $MODEL_FILE and $TOKENS_FILE" >&2
    exit 1
  fi
  if [[ "$verify" == "yes" ]]; then
    verify_file "$staged_model" "$MODEL_BYTES" "$MODEL_SHA256" "$MODEL_FILE"
    verify_file "$staged_tokens" "$TOKENS_BYTES" "$TOKENS_SHA256" "$TOKENS_FILE"
  fi
  mv -f "$staged_model" "$DEST/$MODEL_FILE"
  mv -f "$staged_tokens" "$DEST/$TOKENS_FILE"
  rm -rf "$STAGE"
}

print_identity() {
  echo "# --- paste into lib/voice/voice_assets.dart -------------------------------"
  echo "const String sherpaModelArchiveSha256 ="
  echo "    '$(sha256_of "$ARCHIVE")';"
  echo "const List<SherpaAssetIdentity> sherpaAssetIdentities = <SherpaAssetIdentity>["
  echo "  SherpaAssetIdentity("
  echo "    assetPath: sherpaModelAsset,"
  echo "    fileName: '$MODEL_FILE',"
  echo "    bytes: $(size_of "$DEST/$MODEL_FILE"),"
  echo "    sha256: '$(sha256_of "$DEST/$MODEL_FILE")',"
  echo "  ),"
  echo "  SherpaAssetIdentity("
  echo "    assetPath: sherpaTokensAsset,"
  echo "    fileName: '$TOKENS_FILE',"
  echo "    bytes: $(size_of "$DEST/$TOKENS_FILE"),"
  echo "    sha256: '$(sha256_of "$DEST/$TOKENS_FILE")',"
  echo "  ),"
  echo "];"
  echo "# --------------------------------------------------------------------------"
}

if [[ "$mode" == "print" ]]; then
  download
  if [[ ! -f "$DEST/$MODEL_FILE" || ! -f "$DEST/$TOKENS_FILE" ]]; then
    extract no
  fi
  print_identity
  exit 0
fi

if [[ "$mode" != "force" &&
      "$(size_of "$DEST/$MODEL_FILE" 2>/dev/null || echo 0)" == "$MODEL_BYTES" &&
      "$(size_of "$DEST/$TOKENS_FILE" 2>/dev/null || echo 0)" == "$TOKENS_BYTES" &&
      "$(sha256_of "$DEST/$MODEL_FILE" 2>/dev/null || echo none)" == "$MODEL_SHA256" &&
      "$(sha256_of "$DEST/$TOKENS_FILE" 2>/dev/null || echo none)" == "$TOKENS_SHA256" ]]; then
  echo "$DEST already holds both files at their recorded identity; nothing to do"
  exit 0
fi

download
verify_archive
extract yes
echo "provisioned $MODEL_FILE ($MODEL_BYTES bytes) and $TOKENS_FILE ($TOKENS_BYTES bytes)"
echo "into $DEST"
echo
echo "flutter build now bundles the model; expect the APK to grow by about 126 MB."
