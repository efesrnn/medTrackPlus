import 'package:medTrackPlus/beta/models/manual_medication.dart';

/// CRUD operations for ManualMedication documents.
/// Firestore path: users/{uid}/manual_medications/{medId}
abstract class IDeviceFreeService {
  /// Returns all medications for the given user.
  Future<List<ManualMedication>> getAll(String userId);

  /// Returns a single medication by ID. Null if not found.
  Future<ManualMedication?> getById(String userId, String medId);

  /// Creates a new medication document. [medication.id] is used as the doc ID.
  Future<void> create(String userId, ManualMedication medication);

  /// Updates an existing medication document.
  Future<void> update(String userId, ManualMedication medication);

  /// Deletes a medication document.
  Future<void> delete(String userId, String medId);

  /// Streams real-time updates for all medications of a user.
  Stream<List<ManualMedication>> watchAll(String userId);
}
