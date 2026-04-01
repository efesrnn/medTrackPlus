import 'package:medTrackPlus/beta/enums/app_mode.dart';

enum VerificationClassification { rejected, suspicious, success }

/// Final output of a completed verification session.
/// Stored under: users/{uid}/verifications/{id}
class VerificationResult {
  final String id;

  /// Overall accuracy score 0.0–1.0.
  final double accuracyScore;

  final VerificationClassification classification;

  /// Whether the patient's physical presence was confirmed by face detection.
  final bool presenceDetected;

  final AppMode appMode;

  /// Component scores keyed by name (e.g. 'pillDetection', 'mouthVerification').
  final Map<String, double> subScores;

  /// Firebase Storage URL of the recorded session footage. Empty if not uploaded.
  final String footageUrl;

  /// Index of the medication section / dispense event this result belongs to.
  final int sectionIndex;

  final DateTime timestamp;

  const VerificationResult({
    required this.id,
    required this.accuracyScore,
    required this.classification,
    required this.presenceDetected,
    required this.appMode,
    required this.subScores,
    required this.footageUrl,
    required this.sectionIndex,
    required this.timestamp,
  });

  Map<String, dynamic> toFirestore() => {
        'accuracyScore': accuracyScore,
        'classification': classification.name,
        'presenceDetected': presenceDetected,
        'appMode': appMode.name,
        'subScores': subScores,
        'footageUrl': footageUrl,
        'sectionIndex': sectionIndex,
        'timestamp': timestamp.toIso8601String(),
      };

  factory VerificationResult.fromFirestore(String id, Map<String, dynamic> data) =>
      VerificationResult(
        id: id,
        accuracyScore: (data['accuracyScore'] as num).toDouble(),
        classification: VerificationClassification.values.byName(data['classification']),
        presenceDetected: data['presenceDetected'] as bool,
        appMode: AppMode.values.byName(data['appMode']),
        subScores: Map<String, double>.from(data['subScores'] ?? {}),
        footageUrl: data['footageUrl'] ?? '',
        sectionIndex: data['sectionIndex'] as int,
        timestamp: DateTime.parse(data['timestamp']),
      );
}
