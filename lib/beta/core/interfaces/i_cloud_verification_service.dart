import 'package:medTrackPlus/beta/models/verification_result.dart';

/// Handles persistence and remote operations for verification results.
abstract class ICloudVerificationService {
  /// Saves a [VerificationResult] to Firestore under
  /// users/{uid}/verifications/{result.id}.
  Future<void> save(String userId, VerificationResult result);

  /// Uploads local footage at [localPath] to Firebase Storage and
  /// returns the download URL.
  Future<String> upload(String userId, String localPath);

  /// Returns aggregated verification statistics for a user.
  /// Keys: 'totalSessions', 'successRate', 'averageScore', etc.
  Future<Map<String, dynamic>> stats(String userId);
}
