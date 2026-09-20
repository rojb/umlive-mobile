import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import 'voice_assets.dart';

/// Why offline recognition cannot be offered, when it cannot.
enum SherpaProvisionProblem {
  /// The model files are on disk and matched their recorded identity.
  none,

  /// The APK does not carry the model. `pubspec.yaml` declares those assets, so
  /// this means the build did not include them: the fetch script was never run.
  assetsMissingFromApk,

  /// The copy itself failed — no space, no permission, an interrupted stream.
  copyFailed,

  /// A file arrived but is not the file that was measured.
  identityMismatch,
}

/// Real filesystem paths the recognizer reads.
class SherpaModelPaths {
  const SherpaModelPaths({
    required this.directory,
    required this.model,
    required this.tokens,
  });

  final String directory;
  final String model;
  final String tokens;
}

/// Outcome of provisioning, with the reason when it did not work.
class SherpaProvisionResult {
  const SherpaProvisionResult({
    required this.problem,
    this.paths,
    this.detail,
  });

  final SherpaProvisionProblem problem;
  final SherpaModelPaths? paths;

  /// Machine detail for the log. Never rendered: the screen shows a sentence
  /// from `AppLocalizations`, not an exception string.
  final String? detail;

  bool get isReady => problem == SherpaProvisionProblem.none && paths != null;
}

/// Copies the bundled model out of the APK into a real directory, once.
///
/// `sherpa_onnx` opens ordinary files, so the model has to exist on disk before
/// a recognizer can be built. The copy is streamed by a Kotlin method channel
/// (`AssetManager` -> file), which keeps the whole 126 MB out of the Dart heap;
/// `rootBundle.load` would materialise it there in one `ByteData`.
///
/// Idempotent: a run whose destination already holds both files at their
/// recorded size, with a marker written by the run that verified their digests,
/// copies nothing. Any mismatch re-copies and re-verifies, so a half-written or
/// corrupted provision is repaired instead of used.
class SherpaModelProvisioner {
  SherpaModelProvisioner({
    MethodChannel? channel,
    Future<Directory> Function()? supportDirectory,
  })  : _channel = channel ?? const MethodChannel(_channelName),
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const String _channelName = 'com.umlive.voice/assets';
  static const int _markerVersion = 1;

  final MethodChannel _channel;
  final Future<Directory> Function() _supportDirectory;

  Future<SherpaProvisionResult> provision({
    void Function(String file, int copied, int total)? onProgress,
  }) async {
    final Directory directory;
    try {
      final support = await _supportDirectory();
      directory = Directory(p.join(support.path, 'sherpa-es'));
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
    } on Object catch (error) {
      // A device without a writable files directory cannot run offline voice,
      // and saying so is better than a half-provisioned app.
      logEvent('stt', {
        'kind': 'provision',
        'result': 'failed',
        'reason': 'no_files_directory',
        'error': error.runtimeType.toString(),
      });
      return const SherpaProvisionResult(
        problem: SherpaProvisionProblem.copyFailed,
        detail: 'application support directory unavailable',
      );
    }

    final marker = _readMarker(directory);
    if (_matchesMarker(marker, directory)) {
      final paths = _pathsFor(directory);
      logEvent('stt', {
        'kind': 'provision',
        'result': 'skipped',
        'reason': 'destination_matches',
        'files': sherpaAssetIdentities.length,
        'dir': directory.path,
      });
      return SherpaProvisionResult(
        problem: SherpaProvisionProblem.none,
        paths: paths,
      );
    }

    _channel.setMethodCallHandler(_handlePlatformCall(onProgress));

    try {
      for (final identity in sherpaAssetIdentities) {
        final destination = p.join(directory.path, identity.fileName);
        final started = DateTime.now();
        final Map<Object?, Object?> answer;
        try {
          answer = (await _channel.invokeMethod<Map<Object?, Object?>>(
                'copyAsset',
                <String, Object?>{
                  'path': identity.assetPath,
                  'destination': destination,
                },
              )) ??
              const <Object?, Object?>{};
        } on MissingPluginException {
          logEvent('stt', {
            'kind': 'provision',
            'result': 'failed',
            'reason': 'channel_missing',
            'file': identity.fileName,
          });
          return SherpaProvisionResult(
            problem: SherpaProvisionProblem.copyFailed,
            detail: 'asset channel unavailable',
          );
        } on PlatformException catch (error) {
          final missing = error.code == 'assetMissing';
          logEvent('stt', {
            'kind': 'provision',
            'result': 'failed',
            'reason': missing ? 'asset_missing' : 'copy_failed',
            'file': identity.fileName,
            'error': error.code,
          });
          return SherpaProvisionResult(
            problem: missing
                ? SherpaProvisionProblem.assetsMissingFromApk
                : SherpaProvisionProblem.copyFailed,
            detail: error.message,
          );
        }

        final elapsedMs = DateTime.now().difference(started).inMilliseconds;
        final bytes = answer['bytes'] as int? ?? -1;
        final sha256 = (answer['sha256'] as String? ?? '').toLowerCase();
        final assetKey = answer['key'] as String? ?? 'unknown';

        if (bytes != identity.bytes || sha256 != identity.sha256) {
          // Never accept a file that is not the one that was measured: a
          // truncated model would fail at recognizer construction, silently and
          // much later.
          logEvent('stt', {
            'kind': 'provision',
            'result': 'failed',
            'reason': 'identity_mismatch',
            'file': identity.fileName,
            'expected_bytes': identity.bytes,
            'actual_bytes': bytes,
            'expected_sha256': identity.sha256,
            'actual_sha256': sha256.isEmpty ? 'none' : sha256,
          });
          return SherpaProvisionResult(
            problem: SherpaProvisionProblem.identityMismatch,
            detail: '${identity.fileName}: expected ${identity.sha256}, '
                'got ${sha256.isEmpty ? 'no digest' : sha256}',
          );
        }

        logEvent('stt', {
          'kind': 'provision',
          'op': 'copy',
          'file': identity.fileName,
          'bytes': bytes,
          'sha256': identity.sha256,
          'asset_key': assetKey,
          'ms': elapsedMs,
        });
      }

      _writeMarker(directory);
      final paths = _pathsFor(directory);
      logEvent('stt', {
        'kind': 'provision',
        'result': 'ready',
        'files': sherpaAssetIdentities.length,
        'bytes': sherpaAssetIdentities.fold<int>(0, (sum, a) => sum + a.bytes),
        'dir': directory.path,
      });
      return SherpaProvisionResult(
        problem: SherpaProvisionProblem.none,
        paths: paths,
      );
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<Object?> Function(MethodCall) _handlePlatformCall(
    void Function(String file, int copied, int total)? onProgress,
  ) {
    return (MethodCall call) async {
      if (call.method != 'progress') return null;
      final arguments = (call.arguments as Map?) ?? const <Object?, Object?>{};
      final copied = arguments['copied'] as int? ?? 0;
      final total = arguments['total'] as int? ?? -1;
      final path = arguments['path'] as String? ?? '';
      if (onProgress != null) {
        onProgress(p.basename(path), copied, total);
      }
      return null;
    };
  }

  SherpaModelPaths _pathsFor(Directory directory) => SherpaModelPaths(
        directory: directory.path,
        model: p.join(directory.path, sherpaAssetIdentities[0].fileName),
        tokens: p.join(directory.path, sherpaAssetIdentities[1].fileName),
      );

  Map<String, Object?>? _readMarker(Directory directory) {
    final file = File(p.join(directory.path, '_provision.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      // An unreadable marker is the same as no marker: re-provision.
      return null;
    }
  }

  bool _matchesMarker(Map<String, Object?>? marker, Directory directory) {
    if (marker == null || marker['version'] != _markerVersion) return false;
    final files = marker['files'];
    if (files is! Map) return false;
    for (final identity in sherpaAssetIdentities) {
      final entry = files[identity.fileName];
      if (entry is! Map) return false;
      if (entry['bytes'] != identity.bytes) return false;
      if ((entry['sha256'] as String? ?? '').toLowerCase() != identity.sha256) {
        return false;
      }
      final file = File(p.join(directory.path, identity.fileName));
      if (!file.existsSync() || file.lengthSync() != identity.bytes) return false;
    }
    return true;
  }

  void _writeMarker(Directory directory) {
    final marker = <String, Object?>{
      'version': _markerVersion,
      'files': <String, Object?>{
        for (final identity in sherpaAssetIdentities)
          identity.fileName: <String, Object?>{
            'bytes': identity.bytes,
            'sha256': identity.sha256,
          },
      },
    };
    File(p.join(directory.path, '_provision.json'))
        .writeAsStringSync(jsonEncode(marker));
  }
}
