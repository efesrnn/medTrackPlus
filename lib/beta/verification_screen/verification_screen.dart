import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:medTrackPlus/beta/mlkit_test/face_detection_service.dart';
import 'package:medTrackPlus/beta/mlkit_test/face_painter.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/enums/verification_state.dart';
import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart' as vr;
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';
import 'package:medTrackPlus/beta/verification/cloud_verification_service.dart';
import 'package:medTrackPlus/beta/camera_test/camera_stream_manager.dart';
import 'package:medTrackPlus/beta/camera_test/video_clip_extractor.dart';
import 'package:uuid/uuid.dart';

class VerificationScreen extends StatefulWidget {
  /// If launched from alarm dismiss, pass the alarm's section index.
  final int sectionIndex;
  final AppMode? modeOverride;

  const VerificationScreen({
    super.key,
    this.sectionIndex = 0,
    this.modeOverride,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen>
    with WidgetsBindingObserver {
  // ── Camera ────────────────────────────────────────────────────────────────
  CameraController? _controller;
  bool _isCameraReady = false;
  bool _isFrontCamera = false;
  bool _torchOn = false;
  bool _isProcessingFrame = false;
  Size _imageSize = const Size(480, 640);
  InputImageRotation _rotation = InputImageRotation.rotation0deg;

  // ── Face detection ────────────────────────────────────────────────────────
  final FaceDetectionService _faceDetectionService = FaceDetectionService();
  FaceDetectionResult? _lastResult;

  // ── Cloud & scoring services ────────────────────────────────────────────
  final CloudVerificationService _cloudService = CloudVerificationService();
  final AccuracyScoringEngine _scoringEngine = AccuracyScoringEngine();
  final VideoClipExtractor _clipExtractor = VideoClipExtractor();
  final VideoFrameBuffer _videoBuffer = VideoFrameBuffer();

  // ── Verification state machine ────────────────────────────────────────────
  VerificationState _verificationState = VerificationState.idle;
  final List<CVFrameData> _capturedFrames = [];
  Timer? _timeoutTimer;
  Timer? _stateTimer;

  // ── Pill detection placeholder ────────────────────────────────────────────
  // TODO: Replace with real CVProcessor once pill detection model is ready.
  bool _mockPillDetected = false;

  AppMode get _appMode => widget.modeOverride ?? modeProvider.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopStreaming();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('[VerificationScreen] No cameras found');
        return;
      }

      // Try front camera first, then back camera as fallback
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      final back = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );

      // Order: front cameras first, then back, then any remaining
      final orderedCameras = [...front, ...back, ...cameras]
          .toSet()
          .toList();

      for (final camera in orderedCameras) {
        try {
          debugPrint('[VerificationScreen] Trying camera: ${camera.name}, lens: ${camera.lensDirection}');
          final controller = CameraController(
            camera,
            ResolutionPreset.medium,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.nv21,
          );

          await controller.initialize().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Camera initialize timeout');
            },
          );
          if (!mounted) {
            controller.dispose();
            return;
          }

          _controller = controller;
          _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
          _rotation = InputImageRotationValue.fromRawValue(
                camera.sensorOrientation,
              ) ??
              InputImageRotation.rotation0deg;
          setState(() => _isCameraReady = true);
          _startStreaming();
          return; // Success — stop trying
        } catch (e) {
          debugPrint('[VerificationScreen] Camera ${camera.name} failed: $e');
        }
      }

      debugPrint('[VerificationScreen] All cameras failed to initialize');
    } catch (e) {
      debugPrint('[VerificationScreen] Camera init error: $e');
    }
  }

  void _startStreaming() {
    _controller?.startImageStream((CameraImage image) async {
      if (_isProcessingFrame || _verificationState.isTerminal) return;
      _isProcessingFrame = true;
      try {
        await _processFrame(image);
      } finally {
        _isProcessingFrame = false;
      }
    });
  }

  void _stopStreaming() {
    _controller?.stopImageStream().catchError((_) {});
  }

  Future<void> _processFrame(CameraImage image) async {
    _imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final inputImage = _buildInputImage(image);
    if (inputImage == null) return;

    // Buffer raw Y-plane for VideoClipExtractor
    if (_verificationState != VerificationState.idle &&
        image.planes.isNotEmpty) {
      _videoBuffer.add(BufferedFrame(
        yPlane: Uint8List.fromList(image.planes[0].bytes),
        width: image.width,
        height: image.height,
        timestamp: DateTime.now(),
      ));
    }

    final result = await _faceDetectionService.processImage(inputImage);

    // Collect lip contour points from all four contours.
    final lipContour = <Offset>[];
    for (final contour in [
      result.upperLipTop,
      result.upperLipBottom,
      result.lowerLipTop,
      result.lowerLipBottom,
    ]) {
      if (contour != null) {
        lipContour.addAll(
          contour.points.map((p) => Offset(p.x.toDouble(), p.y.toDouble())),
        );
      }
    }

    final frameData = CVFrameData(
      // TODO: Replace mock pill detection with CVProcessor.processFrame()
      pillDetected: _mockPillDetected,
      pillConfidence: _mockPillDetected ? 0.85 : 0.0,
      pillBoundingBox: Rect.zero,
      faceDetected: result.faceDetected,
      lipContour: lipContour,
      mouthOpenRatio: result.mouthOpenRatio,
      faceBoundingBox: result.face?.boundingBox ?? Rect.zero,
      headYaw: result.headYaw,
      headPitch: result.headPitch,
      headRoll: result.headRoll,
      isFaceFrontal: result.isFaceFrontal,
      timestamp: DateTime.now(),
    );

    if (_verificationState != VerificationState.idle) {
      _capturedFrames.add(frameData);
    }

    if (mounted) {
      setState(() => _lastResult = result);
      _advanceStateMachine(frameData);
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final camera = _controller?.description;
    if (camera == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(
          camera.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;

    if (image.format.group != ImageFormatGroup.nv21) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ── State machine ─────────────────────────────────────────────────────────

  void _advanceStateMachine(CVFrameData frame) {
    switch (_verificationState) {
      case VerificationState.waitingForPill:
        if (frame.pillDetected) _transition(VerificationState.pillDetected);
        break;

      case VerificationState.pillDetected:
        // Pill moves toward lip → approximate by checking face + pill proximity.
        // TODO: Replace with real spatial tracking once pill detection is ready.
        if (frame.pillDetected && frame.faceDetected) {
          _transition(VerificationState.trackingToLip);
        }
        break;

      case VerificationState.trackingToLip:
        if (!frame.pillDetected) {
          // Pill disappeared near mouth — assume consumed.
          _transition(VerificationState.pillConsumed);
        }
        break;

      case VerificationState.pillConsumed:
        _transition(VerificationState.mouthCheckPrompt);
        break;

      case VerificationState.mouthCheckPrompt:
        if (frame.isMouthOpen) _transition(VerificationState.mouthVerified);
        break;

      case VerificationState.mouthVerified:
        _transition(VerificationState.scoring);
        break;

      case VerificationState.scoring:
        _finishScoring();
        break;

      default:
        break;
    }
  }

  void _transition(VerificationState next) {
    if (_verificationState == next) return;
    setState(() => _verificationState = next);

    if (next == VerificationState.mouthCheckPrompt) {
      // Give user 10 s to open mouth.
      _stateTimer?.cancel();
      _stateTimer = Timer(const Duration(seconds: 10), () {
        if (_verificationState == VerificationState.mouthCheckPrompt) {
          _transition(VerificationState.timeout);
        }
      });
    }
  }

  Future<void> _finishScoring() async {
    _stopStreaming();
    _timeoutTimer?.cancel();
    _stateTimer?.cancel();

    try {
      // 1. Calculate accuracy score
      final pillScore = _capturedFrames.where((f) => f.pillDetected).length /
          (_capturedFrames.isEmpty ? 1 : _capturedFrames.length);
      final mouthScore =
          _capturedFrames.where((f) => f.isMouthOpen).length /
              (_capturedFrames.isEmpty ? 1 : _capturedFrames.length);

      final score = _scoringEngine.calculate(
        mode: _appMode == AppMode.device
            ? ScoringMode.withDevice
            : ScoringMode.deviceFree,
        pill: pillScore.clamp(0.0, 1.0),
        lip: pillScore.clamp(0.0, 1.0),
        mouth: mouthScore.clamp(0.0, 1.0),
        timing: 0.8,
      );

      final classification = _scoringEngine.classify(score);

      // 2. Extract clip if suspicious
      String footageUrl = '';
      final userId = FirebaseAuth.instance.currentUser?.uid;

      if (userId != null &&
          classification == VerificationResult.suspicious) {
        final clipPath = await _clipExtractor.extractIfSuspicious(
          classification: classification,
          buffer: _videoBuffer,
          criticalTimestamps: _capturedFrames
              .where((f) => f.pillDetected)
              .map((f) => f.timestamp)
              .toList(),
          criticalLabels: ['pill_detected', 'pill_consumed'],
        );

        if (clipPath != null) {
          try {
            footageUrl = await _cloudService.upload(userId, clipPath);
          } catch (e) {
            debugPrint('[VerificationScreen] Upload failed: $e');
          }
        }
      }

      // 3. Save verification result to Firestore
      if (userId != null) {
        final result = vr.VerificationResult(
          id: const Uuid().v4(),
          accuracyScore: score,
          classification: _mapClassification(classification),
          presenceDetected:
              _capturedFrames.any((f) => f.faceDetected),
          appMode: _appMode,
          subScores: {
            'pill': pillScore,
            'mouth': mouthScore,
            'timing': 0.8,
          },
          footageUrl: footageUrl,
          sectionIndex: widget.sectionIndex,
          timestamp: DateTime.now(),
        );

        await _cloudService.save(userId, result);
      }
    } catch (e) {
      debugPrint('[VerificationScreen] Scoring/save error: $e');
    }

    _transition(VerificationState.completed);
  }

  vr.VerificationClassification _mapClassification(
      VerificationResult engineResult) {
    switch (engineResult) {
      case VerificationResult.rejected:
        return vr.VerificationClassification.rejected;
      case VerificationResult.suspicious:
        return vr.VerificationClassification.suspicious;
      case VerificationResult.success:
        return vr.VerificationClassification.success;
    }
  }

  void _startVerification() {
    _capturedFrames.clear();
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 60), () {
      if (!_verificationState.isTerminal) {
        _transition(VerificationState.timeout);
      }
    });
    setState(() => _verificationState = VerificationState.waitingForPill);
  }

  void _cancelVerification() {
    _timeoutTimer?.cancel();
    _stateTimer?.cancel();
    _transition(VerificationState.cancelled);
  }

  Future<void> _toggleTorch() async {
    if (_controller == null) return;
    _torchOn = !_torchOn;
    await _controller!.setFlashMode(
      _torchOn ? FlashMode.torch : FlashMode.off,
    );
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera preview
          if (_isCameraReady && _controller != null)
            _MirroredPreview(controller: _controller!)
          else
            const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue),
            ),

          // 2. Face detection overlay
          if (_isCameraReady && _lastResult != null)
            CustomPaint(
              painter: FacePainter(
                _lastResult!.face != null ? [_lastResult!.face!] : [],
                imageSize: _imageSize,
                rotation: _rotation,
                isFrontCamera: _isFrontCamera,
              ),
            ),

          // 3. Top bar
          _TopBar(
            appMode: _appMode,
            torchOn: _torchOn,
            onTorchToggle: _toggleTorch,
            onClose: () {
              _cancelVerification();
              Navigator.of(context).pop();
            },
          ),

          // 4. Guidance overlay
          _GuidanceOverlay(state: _verificationState),

          // 5. Progress bar + bottom controls
          _BottomControls(
            state: _verificationState,
            onStart: _startVerification,
            onCancel: _cancelVerification,
            onDone: () => Navigator.of(context).pop(),
            // DEV: mock pill toggle (remove when real CVProcessor is wired)
            onMockPillToggle: () =>
                setState(() => _mockPillDetected = !_mockPillDetected),
            mockPillActive: _mockPillDetected,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    _stateTimer?.cancel();
    _stopStreaming();
    _controller?.dispose();
    _faceDetectionService.dispose();
    super.dispose();
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _MirroredPreview extends StatelessWidget {
  final CameraController controller;
  const _MirroredPreview({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..scale(-1.0, 1.0),
      child: CameraPreview(controller),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AppMode appMode;
  final bool torchOn;
  final VoidCallback onTorchToggle;
  final VoidCallback onClose;

  const _TopBar({
    required this.appMode,
    required this.torchOn,
    required this.onTorchToggle,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: onClose,
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      appMode == AppMode.device
                          ? Icons.medication_liquid_rounded
                          : Icons.smartphone_rounded,
                      color: AppColors.turquoise,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      appMode == AppMode.device ? 'Device' : 'Device-Free',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  torchOn ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                  color: torchOn ? Colors.yellow : Colors.white,
                ),
                onPressed: onTorchToggle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuidanceOverlay extends StatelessWidget {
  final VerificationState state;
  const _GuidanceOverlay({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state == VerificationState.idle) return const SizedBox.shrink();

    final isError = state == VerificationState.timeout ||
        state == VerificationState.cancelled;
    final isSuccess = state == VerificationState.completed ||
        state == VerificationState.mouthVerified;

    final color = isError
        ? Colors.red.shade400
        : isSuccess
            ? AppColors.turquoise
            : Colors.white;

    final icon = isError
        ? Icons.error_outline_rounded
        : isSuccess
            ? Icons.check_circle_outline_rounded
            : Icons.info_outline_rounded;

    return Positioned(
      top: 120,
      left: 24,
      right: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                state.label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final VerificationState state;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onDone;
  final VoidCallback onMockPillToggle;
  final bool mockPillActive;

  const _BottomControls({
    required this.state,
    required this.onStart,
    required this.onCancel,
    required this.onDone,
    required this.onMockPillToggle,
    required this.mockPillActive,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress bar
              if (state != VerificationState.idle)
                Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: state.progress,
                        minHeight: 6,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          state == VerificationState.timeout ||
                                  state == VerificationState.cancelled
                              ? Colors.red
                              : AppColors.turquoise,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),

              // DEV: Mock pill toggle (visible only during active session)
              if (state != VerificationState.idle &&
                  !state.isTerminal &&
                  state != VerificationState.completed)
                GestureDetector(
                  onTap: onMockPillToggle,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: mockPillActive
                          ? Colors.orange.withOpacity(0.2)
                          : Colors.white12,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: mockPillActive ? Colors.orange : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.science_rounded,
                            size: 14,
                            color: mockPillActive
                                ? Colors.orange
                                : Colors.white54),
                        const SizedBox(width: 8),
                        Text(
                          mockPillActive
                              ? 'Mock pill: ON'
                              : 'Mock pill: OFF',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: mockPillActive
                                ? Colors.orange
                                : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Action button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: _actionButton(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton() {
    if (state == VerificationState.idle) {
      return _GradientButton(
        label: 'Start Verification',
        icon: Icons.play_arrow_rounded,
        onTap: onStart,
      );
    }
    if (state.isTerminal || state == VerificationState.completed) {
      return _GradientButton(
        label: 'Done',
        icon: Icons.check_rounded,
        onTap: onDone,
      );
    }
    return OutlinedButton.icon(
      onPressed: onCancel,
      icon: const Icon(Icons.stop_rounded, color: Colors.white70),
      label: Text(
        'Cancel',
        style: GoogleFonts.inter(color: Colors.white70),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.white30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _GradientButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.skyBlue, AppColors.deepSea],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
