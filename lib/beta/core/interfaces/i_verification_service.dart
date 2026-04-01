import 'package:medTrackPlus/beta/enums/verification_state.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart';

/// Drives the verification state machine for a single medication session.
/// Emits [VerificationState] transitions via [stateStream] and
/// produces a [VerificationResult] on completion.
abstract class IVerificationService {
  Stream<VerificationState> get stateStream;

  /// Starts the verification pipeline. Throws if already running.
  void start();

  /// Cancels the current session and emits [VerificationState.cancelled].
  void cancel();

  /// Completes with a result after [VerificationState.completed] is emitted.
  Future<VerificationResult> get result;

  void dispose();
}
