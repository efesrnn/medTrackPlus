import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:medTrackPlus/beta/core/interfaces/i_cloud_verification_service.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart';

/// Concrete implementation of [ICloudVerificationService].
/// Handles saving verification results to Firestore and
/// uploading footage clips to Firebase Storage.
class CloudVerificationService implements ICloudVerificationService {
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  CloudVerificationService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  @override
  Future<void> save(String userId, VerificationResult result) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('verifications')
          .doc(result.id)
          .set(result.toFirestore());

      debugPrint('[CloudVerificationService] Saved verification ${result.id}');
    } catch (e) {
      debugPrint('[CloudVerificationService] Save error: $e');
      rethrow;
    }
  }

  @override
  Future<String> upload(String userId, String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw Exception('File not found: $localPath');
      }

      final fileName =
          'verifications/$userId/${DateTime.now().millisecondsSinceEpoch}.raw';
      final ref = _storage.ref().child(fileName);

      final uploadTask = ref.putFile(
        file,
        SettableMetadata(contentType: 'application/octet-stream'),
      );

      uploadTask.snapshotEvents.listen((snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        debugPrint(
            '[CloudVerificationService] Upload progress: ${(progress * 100).toStringAsFixed(0)}%');
      });

      await uploadTask;
      final downloadUrl = await ref.getDownloadURL();

      debugPrint('[CloudVerificationService] Upload complete: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      debugPrint('[CloudVerificationService] Upload error: $e');
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> stats(String userId) async {
    try {
      final querySnapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('verifications')
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      int totalSessions = querySnapshot.docs.length;
      int successCount = 0;
      double totalScore = 0.0;

      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final classification = data['classification'] as String?;
        final score = (data['accuracyScore'] as num?)?.toDouble() ?? 0.0;

        if (classification == 'success') successCount++;
        totalScore += score;
      }

      return {
        'totalSessions': totalSessions,
        'successCount': successCount,
        'successRate':
            totalSessions > 0 ? successCount / totalSessions : 0.0,
        'averageScore':
            totalSessions > 0 ? totalScore / totalSessions : 0.0,
      };
    } catch (e) {
      debugPrint('[CloudVerificationService] Stats error: $e');
      return {
        'totalSessions': 0,
        'successCount': 0,
        'successRate': 0.0,
        'averageScore': 0.0,
      };
    }
  }
}
