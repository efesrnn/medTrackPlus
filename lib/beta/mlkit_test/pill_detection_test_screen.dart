import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pill_detection_service.dart';
import 'pill_painter.dart';

class PillDetectionTestScreen extends StatefulWidget {
  const PillDetectionTestScreen({super.key});

  @override
  State<PillDetectionTestScreen> createState() =>
      _PillDetectionTestScreenState();
}

class _PillDetectionTestScreenState extends State<PillDetectionTestScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isFrontCamera = false;
  late PillOnTongueService _service;
  PillOnTongueResult _lastResult = PillOnTongueResult.empty();
  Size _imageSize = const Size(480, 640);
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  @override
  void initState() {
    super.initState();
    _service = PillOnTongueService();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() => _lastResult = PillOnTongueResult(
              phase: DetectionPhase.noFace,
              mouthOpenRatio: 0.0,
              pillConfidence: 0.0,
              guidance: 'Kamera izni verilmedi ($status)',
              timestamp: DateTime.now(),
            ));
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _lastResult = PillOnTongueResult(
              phase: DetectionPhase.noFace,
              mouthOpenRatio: 0.0,
              pillConfidence: 0.0,
              guidance: 'Kamera bulunamadı',
              timestamp: DateTime.now(),
            ));
        return;
      }

      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      final back = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      final orderedCameras = [...front, ...back, ...cameras].toSet().toList();

      for (final camera in orderedCameras) {
        try {
          _cameraController = CameraController(
            camera,
            ResolutionPreset.medium,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.nv21,
          );

          await _cameraController!.initialize().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Camera initialize timeout');
            },
          );
          if (!mounted) return;

          _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
          _rotation = InputImageRotationValue.fromRawValue(
                camera.sensorOrientation,
              ) ??
              InputImageRotation.rotation0deg;

          setState(() => _isCameraInitialized = true);

          await _cameraController!.startImageStream(_onFrame);
          return;
        } catch (e) {
          debugPrint('[PillDetection] Camera ${camera.name} failed: $e');
          _cameraController?.dispose();
          _cameraController = null;
        }
      }

      setState(() => _lastResult = PillOnTongueResult(
            phase: DetectionPhase.noFace,
            mouthOpenRatio: 0.0,
            pillConfidence: 0.0,
            guidance: 'Kamera başlatılamadı',
            timestamp: DateTime.now(),
          ));
    } catch (e) {
      debugPrint('Camera error: $e');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final result = await _service.processFrame(image, inputImage);
      if (!mounted) return;

      setState(() {
        _lastResult = result;
        _imageSize = Size(image.width.toDouble(), image.height.toDouble());
      });
    } catch (e) {
      debugPrint('Detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _cameraController;
    if (camera == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
        camera.description.sensorOrientation);
    if (rotation == null) return null;

    if (image.format.group != ImageFormatGroup.nv21) return null;
    if (image.planes.isEmpty) return null;

    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _service.dispose();
    super.dispose();
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

  IconData _phaseIcon(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Icons.face_retouching_off;
      case DetectionPhase.faceDetected:
        return Icons.face;
      case DetectionPhase.mouthOpen:
        return Icons.mood;
      case DetectionPhase.pillOnTongue:
        return Icons.medication;
      case DetectionPhase.mouthClosedWithPill:
        return Icons.sentiment_neutral;
      case DetectionPhase.drinking:
        return Icons.local_drink;
      case DetectionPhase.mouthReopened:
        return Icons.mood;
      case DetectionPhase.swallowConfirmed:
        return Icons.check_circle;
      case DetectionPhase.swallowFailed:
        return Icons.cancel;
      case DetectionPhase.timeoutExpired:
        return Icons.timer_off;
    }
  }

  String _phaseLabel(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return 'Yüz Bulunamadı';
      case DetectionPhase.faceDetected:
        return 'Yüz Algılandı';
      case DetectionPhase.mouthOpen:
        return 'Ağız Açık';
      case DetectionPhase.pillOnTongue:
        return 'Hap Dilde';
      case DetectionPhase.mouthClosedWithPill:
        return 'Ağız Kapalı (Hap)';
      case DetectionPhase.drinking:
        return 'İçme';
      case DetectionPhase.mouthReopened:
        return 'Kontrol';
      case DetectionPhase.swallowConfirmed:
        return 'Yutuldu ✓';
      case DetectionPhase.swallowFailed:
        return 'Yutulmadı ✗';
      case DetectionPhase.timeoutExpired:
        return 'Süre Doldu';
    }
  }

  // Step indicator helpers
  bool _stepReached(DetectionPhase phase, int step) {
    // 1: face, 2: mouth open, 3: pill on tongue,
    // 4: mouth closed (with pill), 5: drinking, 6: swallow confirmed
    int reached;
    switch (phase) {
      case DetectionPhase.noFace:
        reached = 0;
        break;
      case DetectionPhase.faceDetected:
        reached = 1;
        break;
      case DetectionPhase.mouthOpen:
        reached = 2;
        break;
      case DetectionPhase.pillOnTongue:
        reached = 3;
        break;
      case DetectionPhase.mouthClosedWithPill:
        reached = 4;
        break;
      case DetectionPhase.drinking:
      case DetectionPhase.mouthReopened:
        reached = 5;
        break;
      case DetectionPhase.swallowConfirmed:
        reached = 6;
        break;
      case DetectionPhase.swallowFailed:
      case DetectionPhase.timeoutExpired:
        reached = 5;
        break;
    }
    return reached >= step;
  }

  @override
  Widget build(BuildContext context) {
    final phase = _lastResult.phase;
    final color = _phaseColor(phase);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pill Detection Test'),
        backgroundColor: color,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Yeniden Başla',
            onPressed: () {
              _service.reset();
              setState(() => _lastResult = PillOnTongueResult.empty());
            },
          ),
        ],
      ),
      body: _isCameraInitialized && _cameraController != null
          ? Column(
              children: [
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AspectRatio(
                          aspectRatio: _cameraController!.value.aspectRatio,
                          child: _cameraController!.buildPreview(),
                        ),
                      ),
                      if (_lastResult.face != null)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: PillPainter(
                              result: _lastResult,
                              imageSize: _imageSize,
                              rotation: _rotation,
                              isFrontCamera: _isFrontCamera,
                            ),
                          ),
                        ),
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_phaseIcon(phase),
                                  color: Colors.white, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                _phaseLabel(phase),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  color: Colors.grey[900],
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: color, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Icon(_phaseIcon(phase), color: color, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _lastResult.guidance,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _stepDot('Yüz', _stepReached(phase, 1), Colors.orange),
                          _stepLine(_stepReached(phase, 2)),
                          _stepDot('Ağız', _stepReached(phase, 2), Colors.blue),
                          _stepLine(_stepReached(phase, 3)),
                          _stepDot('Hap', _stepReached(phase, 3), Colors.green),
                          _stepLine(_stepReached(phase, 4)),
                          _stepDot('Kapat', _stepReached(phase, 4), Colors.amber),
                          _stepLine(_stepReached(phase, 5)),
                          _stepDot('Su', _stepReached(phase, 5), Colors.lightBlue),
                          _stepLine(_stepReached(phase, 6)),
                          _stepDot('Yut', _stepReached(phase, 6),
                              phase == DetectionPhase.swallowFailed
                                  ? Colors.redAccent
                                  : Colors.greenAccent),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        color: Colors.black,
                        child: Text(
                          'Mouth: ${(_lastResult.mouthOpenRatio * 100).toStringAsFixed(1)}% | '
                          'Pill: ${(_lastResult.pillConfidence * 100).toStringAsFixed(0)}% | '
                          'Drink: ${_lastResult.detectedDrinkLabel ?? "-"}',
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_lastResult.guidance),
                ],
              ),
            ),
    );
  }

  Widget _stepDot(String label, bool active, Color color) {
    return Column(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? color : Colors.grey[700],
          ),
          child: active
              ? const Icon(Icons.check, color: Colors.white, size: 14)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: active ? color : Colors.grey,
                fontSize: 10,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _stepLine(bool active) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 18),
        color: active ? Colors.white38 : Colors.grey[800],
      ),
    );
  }
}