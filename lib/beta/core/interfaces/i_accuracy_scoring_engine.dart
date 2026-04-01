import 'package:medTrackPlus/beta/models/cv_frame_data.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart';

/// Calculates an accuracy score and classification from a list of CV frames
/// captured during a verification session.
abstract class IAccuracyScoringEngine {
  /// Returns an overall score 0.0–1.0 and per-component sub-scores.
  double calculateScore(List<CVFrameData> frames);

  /// Returns the sub-scores breakdown used in [VerificationResult.subScores].
  Map<String, double> calculateSubScores(List<CVFrameData> frames);

  /// Classifies the session based on the score.
  VerificationClassification classify(double score);
}
