/// Identity of the on-device recognition model that ships inside the APK.
///
/// The 126 MB blob is deliberately **not** committed to git. It is fetched by
/// hand with `tool/fetch_sherpa_model.sh`, which downloads the archive, checks
/// it against the SHA-256 recorded here and extracts the two files the
/// recognizer needs into `assets/models/sherpa-es/` (git-ignored). A fresh clone
/// therefore has to run that script once before `flutter build` can succeed:
/// `pubspec.yaml` declares those two files as assets, so a build without them
/// fails loudly instead of shipping an app that cannot hear.
///
/// The constants below are the same values the fetch script verifies, and the
/// script can print them (`--print-identity`) so the two never drift. They are
/// what turns "the model was copied" into "the model that arrived is the model
/// that was measured".
library;

/// Directory, relative to `apps/mobile/`, that the fetch script fills.
const String sherpaAssetDirectory = 'assets/models/sherpa-es';

/// Asset keys as declared in `pubspec.yaml`.
const String sherpaModelAsset = '$sherpaAssetDirectory/model.int8.onnx';
const String sherpaTokensAsset = '$sherpaAssetDirectory/tokens.txt';

/// Upstream archive the two files come from.
///
/// `sherpa-onnx-nemo-fast-conformer-ctc-es-1424-int8` is the model measured on
/// the demo handset (PRD-MOBILE.md §10.2, and the "Proven engine configuration"
/// block of `odd/tasks/umlive-voice-flutter-app.md`). Newer alternatives exist
/// in the same release — a streaming zipformer and a quantized moonshine — and
/// are recorded in `docs/architecture.md` §13 as the fallback. Neither is
/// adopted: the measured one is the one that transcribes.
const String sherpaModelArchiveUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
    'sherpa-onnx-nemo-fast-conformer-ctc-es-1424-int8.tar.bz2';

/// SHA-256 of the downloaded archive, recorded from the fetch that provisioned
/// the copy used for device verification.
const String sherpaModelArchiveSha256 =
    '75053ea480a95eb9df7831cf085e016dbde34fb99d017a85faec964bef395b6f';

/// One file the recognizer reads, with the identity it must have on disk.
class SherpaAssetIdentity {
  const SherpaAssetIdentity({
    required this.assetPath,
    required this.fileName,
    required this.bytes,
    required this.sha256,
  });

  /// Key inside the Flutter asset bundle.
  final String assetPath;

  /// File name under the provisioned directory.
  final String fileName;

  /// Exact size in bytes.
  final int bytes;

  /// Lower-case hexadecimal SHA-256 of the file contents.
  final String sha256;
}

/// The acoustic model, and the token table that maps its output to text.
const List<SherpaAssetIdentity> sherpaAssetIdentities = <SherpaAssetIdentity>[
  SherpaAssetIdentity(
    assetPath: sherpaModelAsset,
    fileName: 'model.int8.onnx',
    bytes: 131652445,
    sha256: '9539b206ba7cb46231e24eb1f1d7269370bfd45209c549d70e2bfd0e9f3b021a',
  ),
  SherpaAssetIdentity(
    assetPath: sherpaTokensAsset,
    fileName: 'tokens.txt',
    bytes: 10871,
    sha256: '6191b4853e3654f053c42f6fd184ca53b402987aefdd6ff6baa68034d803ee85',
  ),
];
