import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FacePainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final InputImageRotation rotation;
  final bool isFrontCamera;

  FacePainter(
    this.faces, {
    this.imageSize = const Size(480, 640),
    this.rotation = InputImageRotation.rotation0deg,
    this.isFrontCamera = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final normalPointPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final lipPointPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.fill;

    for (final face in faces) {
      final rect = _transformRect(face.boundingBox, size);
      canvas.drawRect(rect, boxPaint);

      face.contours.forEach((contourType, contour) {
        if (contour == null) return;

        final isLipContour =
            contourType == FaceContourType.upperLipTop ||
                contourType == FaceContourType.upperLipBottom ||
                contourType == FaceContourType.lowerLipTop ||
                contourType == FaceContourType.lowerLipBottom;

        final paintToUse = isLipContour ? lipPointPaint : normalPointPaint;

        for (final point in contour.points) {
          final transformed = _transformPoint(
            Offset(point.x.toDouble(), point.y.toDouble()),
            size,
          );
          canvas.drawCircle(transformed, 2.0, paintToUse);
        }
      });
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

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}