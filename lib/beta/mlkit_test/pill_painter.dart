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

    final faceRect = _transformRect(face.boundingBox, size);
    final facePaint = Paint()
      ..color = _phaseColor(result.phase).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(faceRect, facePaint);

    _drawLipContours(canvas, size, face);

    final phase = result.phase;
    final showMouth = result.mouthRegion != null &&
        (phase == DetectionPhase.mouthOpen ||
            phase == DetectionPhase.pillOnTongue ||
            phase == DetectionPhase.mouthReopened);
    if (showMouth) {
      final displayRect = result.smoothedPillRegion ?? result.mouthRegion!;
      final mouthRect = _transformRect(displayRect, size);

      final isPill = phase == DetectionPhase.pillOnTongue;
      final isVerify = phase == DetectionPhase.mouthReopened;

      final fillColor = isPill
          ? Colors.green
          : isVerify
              ? Colors.cyan
              : Colors.blue;

      canvas.drawRect(
        mouthRect,
        Paint()..color = fillColor.withValues(alpha: 0.25)..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        mouthRect,
        Paint()
          ..color = fillColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );

      final label = isPill
          ? 'PILL DETECTED'
          : isVerify
              ? 'VERIFYING SWALLOW'
              : 'Scanning...';
      _drawLabel(canvas, mouthRect.topLeft, label, fillColor);
    }

    // Last-seen position when waiting for drink / reopen / final result
    final showLastSeen = result.lastSeenPillRegion != null &&
        (phase == DetectionPhase.mouthClosedWithPill ||
            phase == DetectionPhase.drinking ||
            phase == DetectionPhase.swallowConfirmed ||
            phase == DetectionPhase.swallowFailed ||
            phase == DetectionPhase.timeoutExpired);
    if (showLastSeen) {
      final lastRect = _transformRect(result.lastSeenPillRegion!, size);
      final color = _phaseColor(phase);
      canvas.drawRect(
        lastRect,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
      String label;
      switch (phase) {
        case DetectionPhase.mouthClosedWithPill:
          label = 'WAITING FOR DRINK';
          break;
        case DetectionPhase.drinking:
          label = 'DRINKING (${result.detectedDrinkLabel ?? "?"})';
          break;
        case DetectionPhase.swallowConfirmed:
          label = 'SWALLOWED ✓';
          break;
        case DetectionPhase.swallowFailed:
          label = 'NOT SWALLOWED ✗';
          break;
        case DetectionPhase.timeoutExpired:
          label = 'TIMEOUT';
          break;
        default:
          label = '';
      }
      _drawLabel(canvas, lastRect.topLeft, label, color);
    }
  }

  void _drawLabel(Canvas canvas, Offset topLeft, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: ' $text ',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          backgroundColor: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(topLeft.dx, topLeft.dy - 18));
  }

  void _drawLipContours(Canvas canvas, Size canvasSize, Face face) {
    final lipColor = _phaseColor(result.phase);
    final lipPaint = Paint()
      ..color = lipColor
      ..style = PaintingStyle.fill;

    const contourTypes = [
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

  Offset _transformPoint(Offset point, Size canvasSize) {
    double x = point.dx;
    double y = point.dy;

    final Size rotatedSize = _isRotated90or270()
        ? Size(imageSize.height, imageSize.width)
        : imageSize;

    final scaleX = canvasSize.width / rotatedSize.width;
    final scaleY = canvasSize.height / rotatedSize.height;

    x = x * scaleX;
    y = y * scaleY;

    if (isFrontCamera) {
      x = canvasSize.width - x;
    }

    return Offset(x, y);
  }

  Rect _transformRect(Rect rect, Size canvasSize) {
    final topLeft = _transformPoint(rect.topLeft, canvasSize);
    final bottomRight = _transformPoint(rect.bottomRight, canvasSize);

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
      case DetectionPhase.pillOnTongue:
        return Colors.green;
      case DetectionPhase.mouthClosedWithPill:
        return Colors.amber;
      case DetectionPhase.drinking:
        return Colors.lightBlue;
      case DetectionPhase.mouthReopened:
        return Colors.cyan;
      case DetectionPhase.swallowConfirmed:
        return Colors.greenAccent;
      case DetectionPhase.swallowFailed:
        return Colors.redAccent;
      case DetectionPhase.timeoutExpired:
        return Colors.grey;
    }
  }

  @override
  bool shouldRepaint(covariant PillPainter oldDelegate) {
    return oldDelegate.result != result;
  }
}