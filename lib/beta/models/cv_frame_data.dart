import 'package:flutter/material.dart';

/// Raw output of the CV pipeline for a single camera frame.
/// Produced by CVProcessor and consumed by AccuracyScoringEngine.
class CVFrameData {
  final bool pillDetected;
  final double pillConfidence;

  /// Bounding box of the detected pill in image coordinates.
  final Rect pillBoundingBox;

  final bool faceDetected;

  /// Lip landmark points (combined upper + lower contour) in image coordinates.
  final List<Offset> lipContour;

  /// Ratio of mouth opening to face height. 0.0 = closed, ~0.1+ = open.
  final double mouthOpenRatio;

  /// Bounding box of the detected face in image coordinates.
  final Rect faceBoundingBox;

  /// Head pose euler angles in degrees (null when unavailable).
  final double? headYaw;
  final double? headPitch;
  final double? headRoll;

  /// Whether the face is frontal enough for reliable detection.
  final bool isFaceFrontal;

  final DateTime timestamp;

  const CVFrameData({
    required this.pillDetected,
    required this.pillConfidence,
    required this.pillBoundingBox,
    required this.faceDetected,
    required this.lipContour,
    required this.mouthOpenRatio,
    required this.faceBoundingBox,
    this.headYaw,
    this.headPitch,
    this.headRoll,
    this.isFaceFrontal = true,
    required this.timestamp,
  });

  /// Empty frame — no detections.
  factory CVFrameData.empty() => CVFrameData(
        pillDetected: false,
        pillConfidence: 0.0,
        pillBoundingBox: Rect.zero,
        faceDetected: false,
        lipContour: const [],
        mouthOpenRatio: 0.0,
        faceBoundingBox: Rect.zero,
        timestamp: DateTime.now(),
      );

  bool get isMouthOpen => mouthOpenRatio > 0.06;
}
