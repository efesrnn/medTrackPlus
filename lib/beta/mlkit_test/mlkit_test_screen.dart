import 'face_painter.dart';
import 'face_detection_service.dart';
import 'dart:typed_data';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

class MlkitTestScreen extends StatefulWidget {
  const MlkitTestScreen({super.key});

  @override
  State<MlkitTestScreen> createState() => _MlkitTestScreenState();
}

class _MlkitTestScreenState extends State<MlkitTestScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  bool _isFrontCamera = false;
  String _debugText = 'Stream başlamadı';

  bool _isProcessing = false;
  late FaceDetectionService _faceDetectionService;
  List<Face> _faces = [];
  double _mouthOpenRatio = 0.0;
  bool _isMouthOpen = false;
  Size _imageSize = const Size(480, 640);
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  @override
  void initState() {
    super.initState();

    _faceDetectionService = FaceDetectionService();

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      // Runtime kamera izni iste
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() {
          _debugText = 'Kamera izni verilmedi';
        });
        return;
      }

      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        setState(() {
          _debugText = 'Hiç kamera bulunamadı';
        });
        return;
      }

      for (final cam in cameras) {
        debugPrint('Camera: ${cam.name}, lens: ${cam.lensDirection}');
      }

      // Try front camera first, then back camera as fallback
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      final back = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      final orderedCameras = [...front, ...back, ...cameras]
          .toSet()
          .toList();

      for (final camera in orderedCameras) {
        try {
          debugPrint('[MlkitTest] Trying camera: ${camera.name}, lens: ${camera.lensDirection}');
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

          if (!_cameraController!.value.isInitialized) {
            debugPrint('[MlkitTest] Camera ${camera.name} not initialized, trying next');
            _cameraController?.dispose();
            _cameraController = null;
            continue;
          }

          _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
          _rotation = InputImageRotationValue.fromRawValue(
                camera.sensorOrientation,
              ) ??
              InputImageRotation.rotation0deg;

          setState(() {
            _isCameraInitialized = true;
            _debugText = 'Kamera initialize oldu (${camera.lensDirection})';
          });

          await _cameraController!.startImageStream((image) async {
            if (!_isStreaming) {
              _isStreaming = true;
            }

            if (_isProcessing) return;
            _isProcessing = true;

            try {
              final inputImage = _inputImageFromCameraImage(image);
              if (inputImage == null) {
                setState(() {
                  _debugText =
                  'InputImage oluşturulamadı | Format group: ${image.format.group}';
                });
                return;
              }

              final result = await _faceDetectionService.processImage(inputImage);

              setState(() {
                _faces = result.face != null ? [result.face!] : [];
                _mouthOpenRatio = result.mouthOpenRatio;
                _isMouthOpen = result.isMouthOpen;
                _imageSize = Size(image.width.toDouble(), image.height.toDouble());

                _debugText =
                'Faces: ${result.faceDetected ? 1 : 0} | '
                    'Ratio: ${result.mouthOpenRatio.toStringAsFixed(3)} | '
                    'Mouth: ${result.isMouthOpen ? "OPEN" : "CLOSED"}';
              });
            } catch (e) {
              setState(() {
                _debugText = 'Face detection error: $e';
              });
            } finally {
              _isProcessing = false;
            }
          });
          return; // Success — stop trying cameras
        } catch (e) {
          debugPrint('[MlkitTest] Camera ${camera.name} failed: $e');
          _cameraController?.dispose();
          _cameraController = null;
        }
      }

      // All cameras failed
      setState(() {
        _debugText = 'Hiçbir kamera başlatılamadı';
      });
    } catch (e) {
      setState(() {
        _debugText = 'Kamera hatası: $e';
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetectionService.dispose();
    super.dispose();
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController;
    if (camera == null) return null;

    final rotation =
    InputImageRotationValue.fromRawValue(camera.description.sensorOrientation);
    if (rotation == null) return null;

    // Android için sadece NV21 destekle
    if (image.format.group != ImageFormatGroup.nv21) {
      return null;
    }

    if (image.planes.isEmpty) return null;

    final bytes = image.planes.first.bytes;

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: InputImageFormat.nv21,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: metadata,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ML Kit Test Camera'),
      ),
      body: _isCameraInitialized && _cameraController != null
          ? Stack(
        children: [
          Positioned.fill(
            child: AspectRatio(
              aspectRatio: _cameraController!.value.aspectRatio,
              child: _cameraController!.buildPreview(),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: FacePainter(
                _faces,
                imageSize: _imageSize,
                rotation: _rotation,
                isFrontCamera: _isFrontCamera,
              ),
            ),
          ),
          Positioned(
            top: 100,
            left: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Text(
                'Ratio: ${_mouthOpenRatio.toStringAsFixed(3)}\n'
                    'Mouth: ${_isMouthOpen ? "OPEN" : "CLOSED"}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Text(
                _debugText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      )
          : const Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}