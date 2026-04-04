import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mlkit_test/pill_detection_service.dart';
import '../mlkit_test/pill_painter.dart';
import 'camera_state.dart';
import 'video_service.dart';

/// Unified test screen combining:
/// - Ipek's ML Kit face/pill detection with phase indicators and guidance
/// - Ecenaz's Riverpod camera state machine with video recording & upload
class UnifiedTestScreen extends ConsumerStatefulWidget {
  const UnifiedTestScreen({super.key});

  @override
  ConsumerState<UnifiedTestScreen> createState() => _UnifiedTestScreenState();
}

class _UnifiedTestScreenState extends ConsumerState<UnifiedTestScreen> {
  late final PillOnTongueService _pillService;
  PillOnTongueResult _lastResult = PillOnTongueResult.empty();
  Size _imageSize = const Size(480, 640);
  bool _isProcessing = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _pillService = PillOnTongueService();
    _requestPermissionAndInit();
  }

  Future<void> _requestPermissionAndInit() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _permissionDenied = true);
      return;
    }
    // Use front camera (index 1 on most devices) for face detection
    Future.microtask(() {
      ref.read(cameraProvider.notifier).initialize(cameraIndex: 1);
    });
  }

  @override
  void dispose() {
    _pillService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) {
      return Scaffold(
        appBar: AppBar(title: const Text('Unified Test')),
        body: const Center(child: Text('Kamera izni verilmedi')),
      );
    }

    final cameraState = ref.watch(cameraProvider);
    final phase = _lastResult.phase;
    final phaseColor = _phaseColor(phase);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_stateTitle(cameraState)),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: cameraState is CameraPreviewing ||
                    cameraState is CameraStreaming
                ? () => ref.read(cameraProvider.notifier).switchCamera()
                : null,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _StateIndicator(state: cameraState),
          ),
        ],
      ),
      body: Column(
        children: [
          // Camera preview with ML Kit overlay
          Expanded(
            child: _buildPreview(cameraState, phaseColor),
          ),

          // Detection info panel (when streaming)
          if (cameraState is CameraStreaming) _buildDetectionPanel(phaseColor),

          // Compression/upload progress
          if (cameraState is CameraCompressing)
            _ProgressBar(
              label: 'Sıkıştırılıyor...',
              progress: cameraState.progress,
              color: Colors.orange,
            ),
          if (cameraState is CameraUploading)
            _ProgressBar(
              label: 'Yükleniyor...',
              progress: cameraState.progress,
              color: Colors.blue,
            ),

          // Done / Error panels
          if (cameraState is CameraDone) _DonePanel(state: cameraState),
          if (cameraState is CameraError) _ErrorPanel(state: cameraState),

          // Control buttons
          _buildControls(cameraState),
        ],
      ),
    );
  }

  // ── Preview ──────────────────────────────────────────────────────────────

  Widget _buildPreview(CameraState state, Color phaseColor) {
    return switch (state) {
      CameraIdle() => const Center(
          child: Text('Kamera kapalı', style: TextStyle(color: Colors.white54)),
        ),
      CameraInitializing() => const Center(child: CircularProgressIndicator()),
      CameraPreviewing(:final controller) => _buildCameraStack(controller, phaseColor),
      CameraStreaming(:final controller) => _buildCameraStack(controller, phaseColor),
      CameraRecording(:final controller) => Stack(
          children: [
            _buildCameraStack(controller, phaseColor),
            Positioned(
              top: 16,
              right: 16,
              child: _RecordingIndicator(startedAt: state.startedAt),
            ),
          ],
        ),
      CameraCompressing() || CameraUploading() => const Center(
          child: Icon(Icons.video_file, size: 64, color: Colors.white38),
        ),
      CameraDone() => const Center(
          child: Icon(Icons.check_circle, size: 64, color: Colors.green),
        ),
      CameraError() => const Center(
          child: Icon(Icons.error, size: 64, color: Colors.red),
        ),
    };
  }

  Widget _buildCameraStack(CameraController controller, Color phaseColor) {
    if (!controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        // Camera preview
        Positioned.fill(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: controller.buildPreview(),
          ),
        ),
        // ML Kit face/pill overlay
        if (_lastResult.face != null)
          Positioned.fill(
            child: CustomPaint(
              painter: PillPainter(
                result: _lastResult,
                imageSize: _imageSize,
              ),
            ),
          ),
        // Phase indicator badge (top-right)
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: phaseColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_phaseIcon(_lastResult.phase),
                    color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  _phaseLabel(_lastResult.phase),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Detection Info Panel ─────────────────────────────────────────────────

  Widget _buildDetectionPanel(Color phaseColor) {
    final phase = _lastResult.phase;
    final streamState = ref.read(cameraProvider) as CameraStreaming;

    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Guidance text with icon
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: phaseColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: phaseColor, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(_phaseIcon(phase), color: phaseColor, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _lastResult.guidance,
                    style: TextStyle(
                      color: phaseColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Step progress dots
          Row(
            children: [
              _stepDot('Yüz', phase.index >= 1, Colors.orange),
              _stepLine(phase.index >= 1),
              _stepDot('Ağız', phase.index >= 2, Colors.blue),
              _stepLine(phase.index >= 2),
              _stepDot('Hap', phase.index >= 3, Colors.green),
            ],
          ),
          const SizedBox(height: 10),
          // Stats row: frame count + detection metrics
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: Colors.black,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Kare: ${streamState.frameCount}',
                  style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
                Text(
                  'Ağız: ${(_lastResult.mouthOpenRatio * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
                Text(
                  'Hap: ${(_lastResult.pillConfidence * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
                Text(
                  'Px: ${_lastResult.whitePixelCount}/${_lastResult.totalMouthPixels}',
                  style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Controls ─────────────────────────────────────────────────────────────

  Widget _buildControls(CameraState state) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      color: Colors.black87,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: switch (state) {
          CameraPreviewing() => [
              _ControlButton(
                icon: Icons.remove_red_eye,
                label: 'Algılama',
                color: Colors.cyan,
                onPressed: () => _startDetectionStream(),
              ),
              _ControlButton(
                icon: Icons.fiber_manual_record,
                label: 'Kayıt',
                color: Colors.red,
                onPressed: () =>
                    ref.read(cameraProvider.notifier).startRecording(),
              ),
            ],
          CameraStreaming() => [
              _ControlButton(
                icon: Icons.visibility_off,
                label: 'Durdur',
                color: Colors.orange,
                onPressed: () {
                  ref.read(cameraProvider.notifier).stopStreaming();
                  setState(() => _lastResult = PillOnTongueResult.empty());
                },
              ),
              _ControlButton(
                icon: Icons.fiber_manual_record,
                label: 'Kayıt',
                color: Colors.red,
                onPressed: () async {
                  await ref.read(cameraProvider.notifier).stopStreaming();
                  ref.read(cameraProvider.notifier).startRecording();
                },
              ),
            ],
          CameraRecording() => [
              _ControlButton(
                icon: Icons.stop,
                label: 'Durdur & Yükle',
                color: Colors.red,
                onPressed: () => _stopAndUpload(),
              ),
            ],
          CameraDone() || CameraError() => [
              _ControlButton(
                icon: Icons.refresh,
                label: 'Tekrar',
                onPressed: () =>
                    ref.read(cameraProvider.notifier).backToPreview(),
              ),
            ],
          _ => [const SizedBox.shrink()],
        },
      ),
    );
  }

  // ── ML Kit Stream Processing ─────────────────────────────────────────────

  void _startDetectionStream() {
    ref.read(cameraProvider.notifier).startStreaming(
      onFrame: (CameraImage image) async {
        if (_isProcessing) {
          return CvResult(
            detectedObjects: 0,
            confidence: 0,
            processingTime: Duration.zero,
          );
        }
        _isProcessing = true;

        try {
          final inputImage = _buildInputImage(image);
          if (inputImage == null) {
            _isProcessing = false;
            return CvResult(
              detectedObjects: 0,
              confidence: 0,
              processingTime: Duration.zero,
            );
          }

          final sw = Stopwatch()..start();
          final result = await _pillService.processFrame(image, inputImage);
          sw.stop();

          if (mounted) {
            setState(() {
              _lastResult = result;
              _imageSize =
                  Size(image.width.toDouble(), image.height.toDouble());
            });
          }

          return CvResult(
            detectedObjects: result.face != null ? 1 : 0,
            confidence: result.pillConfidence,
            processingTime: sw.elapsed,
          );
        } catch (e) {
          debugPrint('Detection error: $e');
          return CvResult(
            detectedObjects: 0,
            confidence: 0,
            processingTime: Duration.zero,
          );
        } finally {
          _isProcessing = false;
        }
      },
      skipFrames: 2,
    );
  }

  InputImage? _buildInputImage(CameraImage image) {
    final cameraState = ref.read(cameraProvider);
    CameraController? controller;
    if (cameraState is CameraStreaming) {
      controller = cameraState.controller;
    }
    if (controller == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
        controller.description.sensorOrientation);
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

  Future<void> _stopAndUpload() async {
    final notifier = ref.read(cameraProvider.notifier);
    final videoPath = await notifier.stopRecording();
    if (videoPath == null) return;

    final videoService = ref.read(videoServiceProvider);
    await videoService.processAndUpload(videoPath, notifier);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  String _stateTitle(CameraState state) {
    return switch (state) {
      CameraIdle() => 'Birleşik Test',
      CameraInitializing() => 'Başlatılıyor...',
      CameraPreviewing() => 'Önizleme',
      CameraStreaming() => 'Algılama Aktif',
      CameraRecording() => 'Kayıt',
      CameraCompressing() => 'Sıkıştırılıyor',
      CameraUploading() => 'Yükleniyor',
      CameraDone() => 'Tamamlandı',
      CameraError() => 'Hata',
    };
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
      case DetectionPhase.pillDetected:
        return Icons.check_circle;
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
      case DetectionPhase.pillDetected:
        return 'Hap Algılandı!';
    }
  }

  Widget _stepDot(String label, bool active, Color color) {
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? color : Colors.grey[700],
          ),
          child: active
              ? const Icon(Icons.check, color: Colors.white, size: 16)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: active ? color : Colors.grey,
                fontSize: 11,
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

// ── Shared Sub-widgets ───────────────────────────────────────────────────────

class _StateIndicator extends StatelessWidget {
  final CameraState state;
  const _StateIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (state) {
      CameraIdle() => (Colors.grey, Icons.circle),
      CameraInitializing() => (Colors.yellow, Icons.hourglass_empty),
      CameraPreviewing() => (Colors.green, Icons.circle),
      CameraStreaming() => (Colors.cyan, Icons.remove_red_eye),
      CameraRecording() => (Colors.red, Icons.fiber_manual_record),
      CameraCompressing() => (Colors.orange, Icons.compress),
      CameraUploading() => (Colors.blue, Icons.cloud_upload),
      CameraDone() => (Colors.green, Icons.check_circle),
      CameraError() => (Colors.red, Icons.error),
    };
    return Icon(icon, color: color, size: 20);
  }
}

class _ProgressBar extends StatelessWidget {
  final String label;
  final double progress;
  final Color color;
  const _ProgressBar(
      {required this.label, required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70)),
              Text('${(progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white)),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progress, color: color, minHeight: 6),
        ],
      ),
    );
  }
}

class _RecordingIndicator extends StatefulWidget {
  final DateTime startedAt;
  const _RecordingIndicator({required this.startedAt});

  @override
  State<_RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<_RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.red
              .withAlpha(((0.5 + _controller.value * 0.5) * 255).round()),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
            SizedBox(width: 4),
            Text('REC', style: TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _DonePanel extends StatelessWidget {
  final CameraDone state;
  const _DonePanel({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.green.withAlpha(51),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(state.message,
              style: const TextStyle(
                  color: Colors.green, fontWeight: FontWeight.bold)),
          if (state.downloadUrl != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                state.downloadUrl!,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final CameraError state;
  const _ErrorPanel({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.red.withAlpha(51),
      child: Text(
        state.message,
        style: const TextStyle(color: Colors.red),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _ControlButton({
    required this.icon,
    required this.label,
    this.color = Colors.white,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: label,
          backgroundColor: color.withAlpha(51),
          onPressed: onPressed,
          child: Icon(icon, color: color),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}
