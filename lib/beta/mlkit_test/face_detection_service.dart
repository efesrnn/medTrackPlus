import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectionResult {
  final bool faceDetected;
  final double mouthOpenRatio;
  final bool isMouthOpen;
  final Face? face;
  final FaceContour? upperLipTop;
  final FaceContour? upperLipBottom;
  final FaceContour? lowerLipTop;
  final FaceContour? lowerLipBottom;

  /// Head pose euler angles (null when landmarks disabled or face not detected).
  final double? headYaw;
  final double? headPitch;
  final double? headRoll;

  /// Whether the face is frontal enough for reliable detection.
  final bool isFaceFrontal;

  FaceDetectionResult({
    required this.faceDetected,
    required this.mouthOpenRatio,
    required this.isMouthOpen,
    required this.face,
    required this.upperLipTop,
    required this.upperLipBottom,
    required this.lowerLipTop,
    required this.lowerLipBottom,
    this.headYaw,
    this.headPitch,
    this.headRoll,
    this.isFaceFrontal = true,
  });
}

class FaceDetectionService {
  late final FaceDetector _faceDetector;

  /// Maximum head angle (yaw/pitch) in degrees to consider face frontal.
  static const double _maxFrontalAngle = 25.0;

  FaceDetectionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
        enableClassification: true,
        enableLandmarks: true,
      ),
    );
  }

  Future<FaceDetectionResult> processImage(InputImage inputImage) async {
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      return FaceDetectionResult(
        faceDetected: false,
        mouthOpenRatio: 0.0,
        isMouthOpen: false,
        face: null,
        upperLipTop: null,
        upperLipBottom: null,
        lowerLipTop: null,
        lowerLipBottom: null,
      );
    }

    final face = faces.first;

    // Extract head pose angles
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    final roll = face.headEulerAngleZ;

    final isFrontal = (yaw == null || yaw.abs() <= _maxFrontalAngle) &&
        (pitch == null || pitch.abs() <= _maxFrontalAngle);

    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];

    if (upperLipBottom == null || lowerLipTop == null) {
      return FaceDetectionResult(
        faceDetected: true,
        mouthOpenRatio: 0.0,
        isMouthOpen: false,
        face: face,
        upperLipTop: upperLipTop,
        upperLipBottom: upperLipBottom,
        lowerLipTop: lowerLipTop,
        lowerLipBottom: lowerLipBottom,
        headYaw: yaw,
        headPitch: pitch,
        headRoll: roll,
        isFaceFrontal: isFrontal,
      );
    }

    // Use only inner lip contours (upperLipBottom = inner upper edge,
    // lowerLipTop = inner lower edge) for accurate mouth gap measurement.
    final mouthOpenRatio = _calculateMouthOpenRatio(
      upperLipBottom.points,
      lowerLipTop.points,
      face.boundingBox.height,
    );

    final isMouthOpen = mouthOpenRatio > 0.06;

    return FaceDetectionResult(
      faceDetected: true,
      mouthOpenRatio: mouthOpenRatio,
      isMouthOpen: isMouthOpen,
      face: face,
      upperLipTop: upperLipTop,
      upperLipBottom: upperLipBottom,
      lowerLipTop: lowerLipTop,
      lowerLipBottom: lowerLipBottom,
      headYaw: yaw,
      headPitch: pitch,
      headRoll: roll,
      isFaceFrontal: isFrontal,
    );
  }

  /// Computes mouth open ratio using multi-point sampling across inner lip
  /// contours. Instead of a single centroid distance, samples corresponding
  /// points along the inner upper and lower lips, then takes the median
  /// vertical gap. This is more robust against partial contour noise.
  double _calculateMouthOpenRatio(
    List<Point<int>> upperInner,
    List<Point<int>> lowerInner,
    double faceHeight,
  ) {
    if (upperInner.isEmpty || lowerInner.isEmpty || faceHeight <= 0) return 0.0;

    // Sort both contours by x-coordinate for left-to-right correspondence.
    final upperSorted = List<Point<int>>.from(upperInner)
      ..sort((a, b) => a.x.compareTo(b.x));
    final lowerSorted = List<Point<int>>.from(lowerInner)
      ..sort((a, b) => a.x.compareTo(b.x));

    // Sample N evenly spaced points along each contour and measure gaps.
    final sampleCount = min(upperSorted.length, lowerSorted.length);
    if (sampleCount == 0) return 0.0;

    final gaps = <double>[];
    for (int i = 0; i < sampleCount; i++) {
      final uIdx = (i * (upperSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final lIdx = (i * (lowerSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final gap = (lowerSorted[lIdx].y - upperSorted[uIdx].y).abs().toDouble();
      gaps.add(gap);
    }

    // Use median gap for robustness against outlier points.
    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];

    return medianGap / faceHeight;
  }


  Future<void> dispose() async {
    await _faceDetector.close();
  }
}