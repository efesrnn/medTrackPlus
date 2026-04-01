enum VerificationState {
  idle,
  waitingForPill,
  pillDetected,
  trackingToLip,
  pillConsumed,
  mouthCheckPrompt,
  mouthVerified,
  scoring,
  completed,
  timeout,
  cancelled,
}

extension VerificationStateX on VerificationState {
  String get label {
    switch (this) {
      case VerificationState.idle:            return 'Ready';
      case VerificationState.waitingForPill:  return 'Hold pill in front of camera';
      case VerificationState.pillDetected:    return 'Pill detected!';
      case VerificationState.trackingToLip:   return 'Move pill toward your mouth';
      case VerificationState.pillConsumed:    return 'Pill consumed';
      case VerificationState.mouthCheckPrompt:return 'Open your mouth wide';
      case VerificationState.mouthVerified:   return 'Mouth verified!';
      case VerificationState.scoring:         return 'Calculating score...';
      case VerificationState.completed:       return 'Verification complete';
      case VerificationState.timeout:         return 'Verification timed out';
      case VerificationState.cancelled:       return 'Cancelled';
    }
  }

  /// Progress 0.0–1.0 for the UI progress indicator.
  double get progress {
    const order = [
      VerificationState.idle,
      VerificationState.waitingForPill,
      VerificationState.pillDetected,
      VerificationState.trackingToLip,
      VerificationState.pillConsumed,
      VerificationState.mouthCheckPrompt,
      VerificationState.mouthVerified,
      VerificationState.scoring,
      VerificationState.completed,
    ];
    final idx = order.indexOf(this);
    if (idx < 0) return 0.0;
    return idx / (order.length - 1);
  }

  bool get isTerminal =>
      this == VerificationState.completed ||
      this == VerificationState.timeout ||
      this == VerificationState.cancelled;
}
