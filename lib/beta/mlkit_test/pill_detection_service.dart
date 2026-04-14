import 'dart:math';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum DetectionPhase {
  noFace,
  faceDetected,
  mouthOpen,
  pillDetected,
  pillDisappeared,
}

class PillOnTongueResult {
  final DetectionPhase phase;
  final Face? face;
  final double mouthOpenRatio;
  final Rect? mouthRegion;
  final double pillConfidence;
  final int whitePixelCount;
  final int totalMouthPixels;
  final String guidance;
  final DateTime timestamp;

  /// Smoothed pill region averaged over recent frames (reduces jitter).
  final Rect? smoothedPillRegion;

  /// Last position where the pill was seen before disappearing.
  final Rect? lastSeenPillRegion;

  PillOnTongueResult({
    required this.phase,
    this.face,
    required this.mouthOpenRatio,
    this.mouthRegion,
    required this.pillConfidence,
    this.whitePixelCount = 0,
    this.totalMouthPixels = 0,
    required this.guidance,
    required this.timestamp,
    this.smoothedPillRegion,
    this.lastSeenPillRegion,
  });

  factory PillOnTongueResult.empty() => PillOnTongueResult(
        phase: DetectionPhase.noFace,
        mouthOpenRatio: 0.0,
        pillConfidence: 0.0,
        guidance: 'Yüzünüzü kameraya gösterin',
        timestamp: DateTime.now(),
      );
}

class PillOnTongueService {
  late final FaceDetector _faceDetector;

  // Mouth open threshold (ratio of lip distance / face height)
  static const double _mouthOpenThreshold = 0.08;

  // Maximum head angle (yaw/pitch) to accept as frontal
  static const double _maxFrontalAngle = 25.0;

  // Pill detection: minimum white-ish pixel ratio in mouth region
  static const double _pillPixelThreshold = 0.05; // 5% of mouth area
  static const double _pillConfidenceThreshold = 0.4;

  // NV21 Y channel thresholds for "white/light" pill pixels
  // Pill on tongue: bright area (Y > threshold) against dark/pink mouth
  static const int _brightnessThreshold = 160;

  // Stability
  int _consecutivePillFrames = 0;
  static const int _requiredStableFrames = 5;

  // Position buffer: last 10 frames of detected pill regions
  static const int _positionBufferSize = 10;
  final List<Rect> _positionBuffer = [];

  // Disappearance detection
  static const int _disappearanceFrameThreshold = 3;
  int _consecutiveAbsentFrames = 0;
  bool _wasPillDetected = false;
  Rect? _lastSeenPillRegion;

  PillOnTongueService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableContours: true,
        enableClassification: true,
        enableLandmarks: true,
      ),
    );
  }

  Future<PillOnTongueResult> processFrame(
    CameraImage image,
    InputImage inputImage,
  ) async {
    // Step 1: Detect face
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      _consecutivePillFrames = 0;
      _trackAbsence();
      return _buildDisappearanceResultIfNeeded() ??
          PillOnTongueResult(
            phase: DetectionPhase.noFace,
            mouthOpenRatio: 0.0,
            pillConfidence: 0.0,
            guidance: 'Yüzünüzü kameraya gösterin',
            timestamp: DateTime.now(),
            lastSeenPillRegion: _lastSeenPillRegion,
          );
    }

    final face = faces.first;

    // Step 2: Check face angle — reject non-frontal poses
    final yaw = face.headEulerAngleY;
    final pitch = face.headEulerAngleX;
    if ((yaw != null && yaw.abs() > _maxFrontalAngle) ||
        (pitch != null && pitch.abs() > _maxFrontalAngle)) {
      _consecutivePillFrames = 0;
      _trackAbsence();
      return _buildDisappearanceResultIfNeeded(face: face) ??
          PillOnTongueResult(
            phase: DetectionPhase.faceDetected,
            face: face,
            mouthOpenRatio: 0.0,
            pillConfidence: 0.0,
            guidance: 'Lütfen yüzünüzü doğrudan kameraya çevirin',
            timestamp: DateTime.now(),
            lastSeenPillRegion: _lastSeenPillRegion,
          );
    }

    // Step 3: Check mouth open
    final mouthOpenRatio = _calculateMouthOpenRatio(face);

    if (mouthOpenRatio < _mouthOpenThreshold) {
      _consecutivePillFrames = 0;
      _trackAbsence();
      return _buildDisappearanceResultIfNeeded(face: face, mouthOpenRatio: mouthOpenRatio) ??
          PillOnTongueResult(
            phase: DetectionPhase.faceDetected,
            face: face,
            mouthOpenRatio: mouthOpenRatio,
            pillConfidence: 0.0,
            guidance: 'Ağzınızı açın ve hapı dilinizin üstüne koyun',
            timestamp: DateTime.now(),
            lastSeenPillRegion: _lastSeenPillRegion,
          );
    }

    // Step 4: Mouth is open — analyze mouth region for pill
    final mouthRect = _getMouthRegion(face);
    if (mouthRect == null) {
      _trackAbsence();
      return _buildDisappearanceResultIfNeeded(face: face, mouthOpenRatio: mouthOpenRatio) ??
          PillOnTongueResult(
            phase: DetectionPhase.mouthOpen,
            face: face,
            mouthOpenRatio: mouthOpenRatio,
            pillConfidence: 0.0,
            guidance: 'Ağzınız açık — hapı dilinize koyun',
            timestamp: DateTime.now(),
            lastSeenPillRegion: _lastSeenPillRegion,
          );
    }

    // Analyze NV21 pixels in mouth region
    final pillAnalysis = _analyzeMouthRegion(
      image,
      mouthRect,
      inputImage.metadata?.rotation,
    );

    final pillDetectedThisFrame =
        pillAnalysis.confidence >= _pillConfidenceThreshold;

    if (pillDetectedThisFrame) {
      _consecutivePillFrames++;
      _consecutiveAbsentFrames = 0;
      _addToPositionBuffer(mouthRect);
      _lastSeenPillRegion = mouthRect;
      _wasPillDetected = true;
    } else {
      _consecutivePillFrames = max(0, _consecutivePillFrames - 1);
      _trackAbsence();
    }

    final smoothed = _smoothedPosition();
    final isStable = _consecutivePillFrames >= _requiredStableFrames;

    if (isStable) {
      return PillOnTongueResult(
        phase: DetectionPhase.pillDetected,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRect,
        pillConfidence: pillAnalysis.confidence,
        whitePixelCount: pillAnalysis.whitePixels,
        totalMouthPixels: pillAnalysis.totalPixels,
        guidance: 'Hap algılandı! ✓',
        timestamp: DateTime.now(),
        smoothedPillRegion: smoothed,
        lastSeenPillRegion: _lastSeenPillRegion,
      );
    }

    // Check if pill just disappeared
    final disappearanceResult = _buildDisappearanceResultIfNeeded(
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
    );
    if (disappearanceResult != null) return disappearanceResult;

    return PillOnTongueResult(
      phase: DetectionPhase.mouthOpen,
      face: face,
      mouthOpenRatio: mouthOpenRatio,
      mouthRegion: mouthRect,
      pillConfidence: pillAnalysis.confidence,
      whitePixelCount: pillAnalysis.whitePixels,
      totalMouthPixels: pillAnalysis.totalPixels,
      guidance: _consecutivePillFrames > 0
          ? 'Hap algılanıyor... Sabit tutun ($_consecutivePillFrames/$_requiredStableFrames)'
          : 'Ağzınız açık — hapı dilinize koyun',
      timestamp: DateTime.now(),
      smoothedPillRegion: smoothed,
      lastSeenPillRegion: _lastSeenPillRegion,
    );
  }

  /// Track a frame where the pill was not detected.
  void _trackAbsence() {
    if (_wasPillDetected) {
      _consecutiveAbsentFrames++;
    }
  }

  /// If pill was previously detected and now absent for [_disappearanceFrameThreshold]
  /// frames, return a [pillDisappeared] result. Otherwise null.
  PillOnTongueResult? _buildDisappearanceResultIfNeeded({
    Face? face,
    double mouthOpenRatio = 0.0,
    Rect? mouthRegion,
  }) {
    if (_wasPillDetected &&
        _consecutiveAbsentFrames >= _disappearanceFrameThreshold) {
      // Pill disappeared — record event and reset tracking
      final lastPos = _lastSeenPillRegion;
      _wasPillDetected = false;
      _consecutiveAbsentFrames = 0;
      _positionBuffer.clear();
      return PillOnTongueResult(
        phase: DetectionPhase.pillDisappeared,
        face: face,
        mouthOpenRatio: mouthOpenRatio,
        mouthRegion: mouthRegion,
        pillConfidence: 0.0,
        guidance: 'Hap kayboldu — yutulmuş olabilir',
        timestamp: DateTime.now(),
        lastSeenPillRegion: lastPos,
      );
    }
    return null;
  }

  /// Add a pill position to the ring buffer.
  void _addToPositionBuffer(Rect position) {
    _positionBuffer.add(position);
    if (_positionBuffer.length > _positionBufferSize) {
      _positionBuffer.removeAt(0);
    }
  }

  /// Average the buffered positions for jitter smoothing.
  Rect? _smoothedPosition() {
    if (_positionBuffer.isEmpty) return null;
    double l = 0, t = 0, r = 0, b = 0;
    for (final rect in _positionBuffer) {
      l += rect.left;
      t += rect.top;
      r += rect.right;
      b += rect.bottom;
    }
    final n = _positionBuffer.length;
    return Rect.fromLTRB(l / n, t / n, r / n, b / n);
  }

  /// Multi-point median mouth open ratio using inner lip contours.
  /// Samples corresponding points along upper and lower inner lips,
  /// then takes the median vertical gap for noise robustness.
  double _calculateMouthOpenRatio(Face face) {
    final upperLipBottom = face.contours[FaceContourType.upperLipBottom];
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop];

    if (upperLipBottom == null || lowerLipTop == null) return 0.0;
    if (upperLipBottom.points.isEmpty || lowerLipTop.points.isEmpty) return 0.0;

    final faceHeight = face.boundingBox.height;
    if (faceHeight <= 0) return 0.0;

    // Sort by x for left-to-right correspondence
    final upperSorted = List<Point<int>>.from(upperLipBottom.points)
      ..sort((a, b) => a.x.compareTo(b.x));
    final lowerSorted = List<Point<int>>.from(lowerLipTop.points)
      ..sort((a, b) => a.x.compareTo(b.x));

    final sampleCount = min(upperSorted.length, lowerSorted.length);
    if (sampleCount == 0) return 0.0;

    final gaps = <double>[];
    for (int i = 0; i < sampleCount; i++) {
      final uIdx = (i * (upperSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final lIdx = (i * (lowerSorted.length - 1)) ~/ max(1, sampleCount - 1);
      final gap = (lowerSorted[lIdx].y - upperSorted[uIdx].y).abs().toDouble();
      gaps.add(gap);
    }

    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];

    return medianGap / faceHeight;
  }

  Rect? _getMouthRegion(Face face) {
    final upperLipTop = face.contours[FaceContourType.upperLipTop];
    final lowerLipBottom = face.contours[FaceContourType.lowerLipBottom];

    if (upperLipTop == null || lowerLipBottom == null) return null;
    if (upperLipTop.points.isEmpty || lowerLipBottom.points.isEmpty) return null;

    // Build bounding rect from all lip contour points
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final p in [...upperLipTop.points, ...lowerLipBottom.points]) {
      minX = min(minX, p.x.toDouble());
      minY = min(minY, p.y.toDouble());
      maxX = max(maxX, p.x.toDouble());
      maxY = max(maxY, p.y.toDouble());
    }

    // Shrink slightly to focus on inner mouth
    final w = maxX - minX;
    final h = maxY - minY;
    final insetX = w * 0.15;
    final insetY = h * 0.1;

    return Rect.fromLTRB(
      minX + insetX,
      minY + insetY,
      maxX - insetX,
      maxY - insetY,
    );
  }

  _PillPixelAnalysis _analyzeMouthRegion(
    CameraImage image,
    Rect mouthRect,
    InputImageRotation? rotation,
  ) {
    // NV21: first plane is Y (brightness), second plane is VU (interleaved)
    if (image.planes.isEmpty) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final yPlane = image.planes.first.bytes;
    final imgW = image.width;
    final imgH = image.height;
    final bytesPerRow = image.planes.first.bytesPerRow;

    // Clamp mouth rect to image bounds
    final left = mouthRect.left.toInt().clamp(0, imgW - 1);
    final top = mouthRect.top.toInt().clamp(0, imgH - 1);
    final right = mouthRect.right.toInt().clamp(0, imgW - 1);
    final bottom = mouthRect.bottom.toInt().clamp(0, imgH - 1);

    if (right <= left || bottom <= top) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    int whitePixels = 0;
    int totalPixels = 0;

    // Sample every 2nd pixel for performance
    for (int y = top; y < bottom; y += 2) {
      for (int x = left; x < right; x += 2) {
        final idx = y * bytesPerRow + x;
        if (idx >= 0 && idx < yPlane.length) {
          totalPixels++;
          final brightness = yPlane[idx];
          if (brightness >= _brightnessThreshold) {
            whitePixels++;
          }
        }
      }
    }

    if (totalPixels == 0) {
      return _PillPixelAnalysis(0, 0, 0.0);
    }

    final ratio = whitePixels / totalPixels;

    // Confidence: higher when ratio is in sweet spot (5-40%)
    // Too low = no pill, too high = probably teeth or overexposure
    double confidence;
    if (ratio >= _pillPixelThreshold && ratio <= 0.45) {
      // Normalize to 0-1 range within sweet spot
      confidence = ((ratio - _pillPixelThreshold) / (0.30 - _pillPixelThreshold))
          .clamp(0.0, 1.0);
    } else if (ratio > 0.45) {
      // Likely teeth or light — reduce confidence
      confidence = 0.2;
    } else {
      confidence = 0.0;
    }

    return _PillPixelAnalysis(whitePixels, totalPixels, confidence);
  }

  Future<void> dispose() async {
    await _faceDetector.close();
  }
}

class _PillPixelAnalysis {
  final int whitePixels;
  final int totalPixels;
  final double confidence;
  _PillPixelAnalysis(this.whitePixels, this.totalPixels, this.confidence);
}