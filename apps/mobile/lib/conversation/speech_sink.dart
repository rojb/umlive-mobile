/// The port through which the conversation speaks (`T15`, `FR-MD03`).
///
/// A narrow port in the same shape as `OperationExecutor`: the conversation
/// owns one and hands it a sentence, and it knows nothing about the
/// synthesizer, the pinned voice, the engine or the platform behind it —
/// exactly the discipline `OperationExecutor` applies to the backend. The
/// voice layer implements it; `VoiceController` is the app's one
/// implementation (`docs/architecture.md` §13.3), because there is one engine,
/// one pinned `es-US` voice and one place that knows whether synthesis is
/// available at all.
library;

abstract class SpeechSink {
  const SpeechSink();

  /// Speaks [text].
  ///
  /// Never throws for an unavailable engine. A synthesis that cannot run is a
  /// state the voice layer reports on its own surface, and a caller speaks
  /// fire-and-forget: the failure has to become a log line at the caller, not
  /// an exception that could take a turn down (`FR-MD03`). Speech must never
  /// delay, fail or reorder a turn.
  Future<void> speak(String text);
}
