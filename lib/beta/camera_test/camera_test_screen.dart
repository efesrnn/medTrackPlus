library;

import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medTrackPlus/beta/core/interfaces/cv_processor.dart';
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';
import 'camera_state.dart';
import 'camera_stream_manager.dart';
import 'video_service.dart';

class CameraTestScreen extends ConsumerStatefulWidget {
  const CameraTestScreen({super.key});

  @override
  ConsumerState<CameraTestScreen> createState() => _CameraTestScreenState();
}

class _CameraTestScreenState extends ConsumerState<CameraTestScreen> {
  late final CameraStreamManager _manager;

  @override
  void initState() {
    super.initState();
    _manager = CameraStreamManager(
      cvProcessor: _MockCVProcessor(),
      cameraNotifier: ref.read(cameraProvider.notifier),
    );
    Future.microtask(() => _manager.open());
  }

  @override
  void dispose() {
    _manager.stopStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cameraProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_stateTitle(cameraState)),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: cameraState is CameraPreviewing || cameraState is CameraStreaming
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
          Expanded(child: _buildPreview(cameraState)),

          if (cameraState is CameraStreaming)
            _CvResultPanel(state: cameraState, bufferCount: _manager.videoBuffer.length),

          if (cameraState is CameraCompressing)
            _ProgressBar(
              label: 'Compressing...',
              progress: cameraState.progress,
              color: Colors.orange,
            ),
          if (cameraState is CameraUploading)
            _ProgressBar(
              label: 'Uploading...',
              progress: cameraState.progress,
              color: Colors.blue,
            ),

          if (cameraState is CameraDone) _DonePanel(state: cameraState),
          if (cameraState is CameraError) _ErrorPanel(state: cameraState),

          _buildControls(cameraState),
        ],
      ),
    );
  }

  Widget _buildPreview(CameraState state) {
    return switch (state) {
      CameraIdle() => const Center(
          child: Text('Camera off', style: TextStyle(color: Colors.white54)),
        ),
      CameraInitializing() => const Center(child: CircularProgressIndicator()),
      CameraPreviewing(:final controller) => _CameraPreviewWidget(controller: controller),
      CameraStreaming(:final controller) => _CameraPreviewWidget(controller: controller),
      CameraRecording(:final controller) => Stack(
          fit: StackFit.expand,
          children: [
            _CameraPreviewWidget(controller: controller),
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

  Widget _buildControls(CameraState state) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      color: Colors.black87,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: switch (state) {
          CameraPreviewing() => [
              _ControlButton(
                icon: Icons.visibility,
                label: 'Stream',
                onPressed: () => _startStreaming(),
              ),
              _ControlButton(
                icon: Icons.fiber_manual_record,
                label: 'Record',
                color: Colors.red,
                onPressed: () => ref.read(cameraProvider.notifier).startRecording(),
              ),
            ],
          CameraStreaming() => [
              _ControlButton(
                icon: Icons.visibility_off,
                label: 'Stop',
                color: Colors.orange,
                onPressed: () => _manager.stopStream(),
              ),
            ],
          CameraRecording() => [
              _ControlButton(
                icon: Icons.stop,
                label: 'Stop & Upload',
                color: Colors.red,
                onPressed: () => _stopAndUpload(),
              ),
            ],
          CameraDone() || CameraError() => [
              _ControlButton(
                icon: Icons.refresh,
                label: 'Retry',
                onPressed: () => ref.read(cameraProvider.notifier).backToPreview(),
              ),
            ],
          _ => [const SizedBox.shrink()],
        },
      ),
    );
  }

  void _startStreaming() {
    _manager.startStream();
  }

  Future<void> _stopAndUpload() async {
    final notifier = ref.read(cameraProvider.notifier);
    final videoPath = await notifier.stopRecording();
    if (videoPath == null) return;

    final videoService = ref.read(videoServiceProvider);
    await videoService.processAndUpload(videoPath, notifier);
  }

  String _stateTitle(CameraState state) {
    return switch (state) {
      CameraIdle() => 'Camera Test',
      CameraInitializing() => 'Initializing...',
      CameraPreviewing() => 'Preview',
      CameraStreaming() => 'Frame Processing',
      CameraRecording() => 'Recording',
      CameraCompressing() => 'Compressing',
      CameraUploading() => 'Uploading',
      CameraDone() => 'Done',
      CameraError() => 'Error',
    };
  }
}

// -- Sub-widgets --

class _CameraPreviewWidget extends StatelessWidget {
  final CameraController controller;
  const _CameraPreviewWidget({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.previewSize!.height,
          height: controller.value.previewSize!.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

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

class _CvResultPanel extends StatelessWidget {
  final CameraStreaming state;
  final int bufferCount;
  const _CvResultPanel({required this.state, this.bufferCount = 0});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.black87,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _InfoChip('Frames', '${state.frameCount}'),
              _InfoChip('Buffer', '$bufferCount'),
              if (state.lastResult != null) ...[
                _InfoChip('Objects', '${state.lastResult!.detectedObjects}'),
                _InfoChip(
                  'Confidence',
                  '${(state.lastResult!.confidence * 100).toStringAsFixed(0)}%',
                ),
                _InfoChip(
                  'Latency',
                  '${state.lastResult!.processingTime.inMilliseconds}ms',
                ),
              ],
            ],
          ),
          if (state.lastResult != null && state.lastResult!.boundingBoxes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                children: state.lastResult!.boundingBoxes
                    .map((b) => Chip(
                          label: Text(
                            '${b.label} ${(b.confidence * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(fontSize: 11, color: Colors.white),
                          ),
                          backgroundColor: Colors.blueGrey,
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  const _InfoChip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final String label;
  final double progress;
  final Color color;
  const _ProgressBar({required this.label, required this.progress, required this.color});

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
          color: Colors.red.withAlpha(((0.5 + _controller.value * 0.5) * 255).round()),
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
              style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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

// -- Mock CVProcessor (implements real interface, returns CVFrameData) --

class _MockCVProcessor implements CVProcessor {
  final Random _rng = Random();

  @override
  Future<CVFrameData> processFrame(CameraImage frame) async {
    await Future.delayed(const Duration(milliseconds: 40));
    final pill = _rng.nextDouble() > 0.5;
    final face = _rng.nextDouble() > 0.3;
    return CVFrameData(
      pillDetected: pill,
      pillConfidence: pill ? 0.6 + _rng.nextDouble() * 0.4 : 0.0,
      pillBoundingBox: pill ? const Rect.fromLTWH(0.3, 0.4, 0.1, 0.1) : Rect.zero,
      faceDetected: face,
      lipContour: const [],
      mouthOpenRatio: face ? _rng.nextDouble() * 0.15 : 0.0,
      faceBoundingBox: face ? const Rect.fromLTWH(0.2, 0.1, 0.6, 0.7) : Rect.zero,
      timestamp: DateTime.now(),
    );
  }

  @override
  Future<void> dispose() async {}
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