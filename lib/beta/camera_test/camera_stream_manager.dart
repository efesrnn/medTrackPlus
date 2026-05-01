library;

import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:medTrackPlus/beta/core/interfaces/cv_processor.dart';
import 'package:medTrackPlus/beta/camera_test/camera_state.dart';

// ---------------------------------------------------------------------------
// Video frame buffer — ring buffer that stores raw YUV frame snapshots
// ---------------------------------------------------------------------------

class BufferedFrame {
  final Uint8List yPlane;
  final int width;
  final int height;
  final DateTime timestamp;

  const BufferedFrame({
    required this.yPlane,
    required this.width,
    required this.height,
    required this.timestamp,
  });
}

class VideoFrameBuffer {
  final int maxFrames;
  final List<BufferedFrame> _frames = [];

  VideoFrameBuffer({this.maxFrames = 300});

  List<BufferedFrame> get frames => List.unmodifiable(_frames);
  int get length => _frames.length;
  bool get isEmpty => _frames.isEmpty;

  void add(BufferedFrame frame) {
    if (_frames.length >= maxFrames) {
      _frames.removeAt(0);
    }
    _frames.add(frame);
  }

  void clear() => _frames.clear();
}



class CameraStreamManager {
  final CVProcessor _cvProcessor;
  final CameraNotifier _cameraNotifier;
  final VideoFrameBuffer videoBuffer;


  final int skipFrames;

  CameraController? _controller;
  bool _isStreaming = false;
  bool _isDisposed = false;

  int _processedCount = 0;
  bool _processing = false;

  CameraStreamManager({
    required CVProcessor cvProcessor,
    required CameraNotifier cameraNotifier,
    VideoFrameBuffer? videoBuffer,
    this.skipFrames = 2,
  })  : _cvProcessor = cvProcessor,
        _cameraNotifier = cameraNotifier,
        videoBuffer = videoBuffer ?? VideoFrameBuffer();

  bool get isStreaming => _isStreaming;
  int get processedFrames => _processedCount;




  Future<void> open() async {
    if (_isDisposed) return;

    final cameras = await availableCameras();
    final frontIndex = cameras.indexWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
    );

    if (frontIndex == -1) {
      _cameraNotifier.setError('No front camera found');
      return;
    }

    await _cameraNotifier.initialize(cameraIndex: frontIndex);

    // Grab the controller from the notifier's current state.
    final state = _cameraNotifier.currentState;
    if (state is CameraPreviewing) {
      _controller = state.controller;
    }
  }


  Future<void> startStream() async {
    if (_isDisposed || _controller == null || _isStreaming) return;

    final state = _cameraNotifier.currentState;
    if (state is! CameraPreviewing && state is! CameraRecording) return;

    _processedCount = 0;
    _isStreaming = true;
    videoBuffer.clear();

    _cameraNotifier.backToPreview();


    await _cameraNotifier.startStreaming(
      skipFrames: skipFrames,
      onFrame: _onFrame,
    );
  }

  Future<CvResult> _onFrame(CameraImage image) async {
    _bufferFrame(image);

    if (_processing) {
      return CvResult(
        detectedObjects: 0,
        confidence: 0,
        processingTime: Duration.zero,
      );
    }

    _processing = true;
    final stopwatch = Stopwatch()..start();

    try {
      final cvData = await _cvProcessor.processFrame(image);
      stopwatch.stop();
      _processedCount++;

      // Map CVFrameData → CvResult so the notifier state stays consistent.
      final boxes = <BoundingBox>[];

      if (cvData.pillDetected) {
        boxes.add(BoundingBox(
          x: cvData.pillBoundingBox.left,
          y: cvData.pillBoundingBox.top,
          width: cvData.pillBoundingBox.width,
          height: cvData.pillBoundingBox.height,
          label: 'pill',
          confidence: cvData.pillConfidence,
        ));
      }

      if (cvData.faceDetected) {
        boxes.add(BoundingBox(
          x: cvData.faceBoundingBox.left,
          y: cvData.faceBoundingBox.top,
          width: cvData.faceBoundingBox.width,
          height: cvData.faceBoundingBox.height,
          label: 'face',
          confidence: 1.0,
        ));
      }

      return CvResult(
        detectedObjects: boxes.length,
        confidence: cvData.pillConfidence,
        processingTime: stopwatch.elapsed,
        boundingBoxes: boxes,
      );
    } catch (_) {
      stopwatch.stop();
      return CvResult(
        detectedObjects: 0,
        confidence: 0,
        processingTime: stopwatch.elapsed,
      );
    } finally {
      _processing = false;
    }
  }

  /// Copies the Y-plane bytes into the video buffer.
  void _bufferFrame(CameraImage image) {
    if (image.planes.isEmpty) return;

    final yPlane = image.planes[0];
    videoBuffer.add(BufferedFrame(
      yPlane: Uint8List.fromList(yPlane.bytes),
      width: image.width,
      height: image.height,
      timestamp: DateTime.now(),
    ));
  }

  /// Stops the image stream but keeps the camera open (previewing).
  Future<void> stopStream() async {
    if (!_isStreaming) return;
    _isStreaming = false;
    await _cameraNotifier.stopStreaming();
  }

  /// Stops streaming (if active) and releases the camera.
  Future<void> close() async {
    await stopStream();
    _controller = null;
    _cameraNotifier.backToPreview();
  }

  /// Releases all resources. The manager cannot be reused after this.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stopStream();
    videoBuffer.clear();
    await _cvProcessor.dispose();
    _cameraNotifier.dispose();
    _controller = null;
  }
}
