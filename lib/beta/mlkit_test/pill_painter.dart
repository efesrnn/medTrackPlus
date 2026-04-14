import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'pill_detection_service.dart';

class PillPainter extends CustomPainter {
  final PillOnTongueResult result;
  final Size imageSize;
  final InputImageRotation rotation;
  final bool isFrontCamera;

  PillPainter({
    required this.result,
    required this.imageSize,
    this.rotation = InputImageRotation.rotation0deg,
    this.isFrontCamera = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final face = result.face;
    if (face == null) return;

    // Draw face bounding box
    final faceRect = _transformRect(face.boundingBox, size);
    final facePaint = Paint()
      ..color = _phaseColor(result.phase).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(faceRect, facePaint);

    // Draw lip contours
    _drawLipContours(canvas, size, face);

    // Draw mouth region highlight if mouth is open
    final showMouth = result.mouthRegion != null &&
        (result.phase == DetectionPhase.mouthOpen ||
            result.phase == DetectionPhase.pillDetected);
    if (showMouth) {
      // Use smoothed region for pill overlay to reduce jitter
      final displayRect = result.smoothedPillRegion ?? result.mouthRegion!;
      final mouthRect = _transformRect(displayRect, size);

      final mouthPaint = Paint()
        ..color = result.phase == DetectionPhase.pillDetected
            ? Colors.green.withValues(alpha: 0.3)
            : Colors.blue.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill;
      canvas.drawRect(mouthRect, mouthPaint);

      final mouthBorderPaint = Paint()
        ..color = result.phase == DetectionPhase.pillDetected
            ? Colors.green
            : Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(mouthRect, mouthBorderPaint);

      // Label
      final label = result.phase == DetectionPhase.pillDetected
          ? 'PILL DETECTED'
          : 'Scanning...';
      final labelColor = result.phase == DetectionPhase.pillDetected
          ? Colors.green
          : Colors.blue;

      final textPainter = TextPainter(
        text: TextSpan(
          text: ' $label ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            backgroundColor: labelColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(mouthRect.left, mouthRect.top - 18),
      );
    }

    // Draw last-seen position when pill disappeared
    if (result.phase == DetectionPhase.pillDisappeared &&
        result.lastSeenPillRegion != null) {
      final lastRect = _transformRect(result.lastSeenPillRegion!, size);

      final dashedPaint = Paint()
        ..color = Colors.purple.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawRect(lastRect, dashedPaint);

      final labelPainter = TextPainter(
        text: const TextSpan(
          text: ' PILL DISAPPEARED ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.purple,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      labelPainter.paint(
        canvas,
        Offset(lastRect.left, lastRect.top - 18),
      );
    }
  }

  void _drawLipContours(Canvas canvas, Size canvasSize, Face face) {
    final lipColor = result.phase == DetectionPhase.pillDetected
        ? Colors.greenAccent
        : result.phase == DetectionPhase.mouthOpen
            ? Colors.lightBlueAccent
            : Colors.orangeAccent;

    final lipPaint = Paint()
      ..color = lipColor
      ..style = PaintingStyle.fill;

    final contourTypes = [
      FaceContourType.upperLipTop,
      FaceContourType.upperLipBottom,
      FaceContourType.lowerLipTop,
      FaceContourType.lowerLipBottom,
    ];

    for (final type in contourTypes) {
      final contour = face.contours[type];
      if (contour == null) continue;
      for (final point in contour.points) {
        final transformed = _transformPoint(
          Offset(point.x.toDouble(), point.y.toDouble()),
          canvasSize,
        );
        canvas.drawCircle(transformed, 2.5, lipPaint);
      }
    }
  }

  /// Transform a point from image coordinates to canvas coordinates,
  /// accounting for rotation and camera mirroring.
  Offset _transformPoint(Offset point, Size canvasSize) {
    double x = point.dx;
    double y = point.dy;

    // The image size as seen by ML Kit depends on the rotation
    final Size rotatedSize = _isRotated90or270()
        ? Size(imageSize.height, imageSize.width)
        : imageSize;

    // Scale from image space to canvas space
    final scaleX = canvasSize.width / rotatedSize.width;
    final scaleY = canvasSize.height / rotatedSize.height;

    x = x * scaleX;
    y = y * scaleY;

    // Mirror x for front camera
    if (isFrontCamera) {
      x = canvasSize.width - x;
    }

    return Offset(x, y);
  }

  /// Transform a rect from image coordinates to canvas coordinates.
  Rect _transformRect(Rect rect, Size canvasSize) {
    final topLeft = _transformPoint(rect.topLeft, canvasSize);
    final bottomRight = _transformPoint(rect.bottomRight, canvasSize);

    // After mirroring, left/right may swap
    return Rect.fromLTRB(
      topLeft.dx < bottomRight.dx ? topLeft.dx : bottomRight.dx,
      topLeft.dy < bottomRight.dy ? topLeft.dy : bottomRight.dy,
      topLeft.dx > bottomRight.dx ? topLeft.dx : bottomRight.dx,
      topLeft.dy > bottomRight.dy ? topLeft.dy : bottomRight.dy,
    );
  }

  bool _isRotated90or270() {
    return rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
  }

  Color _phaseColor(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Colors.red;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
        return Colors.blue;
      case DetectionPhase.pillDetected:
        return Colors.green;
      case DetectionPhase.pillDisappeared:
        return Colors.purple;
    }
  }

  @override
  bool shouldRepaint(covariant PillPainter oldDelegate) {
    return oldDelegate.result != result;
  }
}