import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_detection_service.dart';
import 'package:medTrackPlus/beta/mlkit_test/pill_painter.dart';
import 'package:medTrackPlus/beta/models/verification_result.dart' as vr;
import 'package:medTrackPlus/beta/providers/mode_provider.dart';
import 'package:medTrackPlus/beta/verification/accuracy_scoring_engine.dart';
import 'package:medTrackPlus/beta/verification/cloud_verification_service.dart';
import 'package:medTrackPlus/main.dart' show AppColors;
import 'package:medTrackPlus/services/consent_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:video_compress/video_compress.dart';

/// Unified medication verification screen.
class VerificationScreen extends StatefulWidget {
  final int sectionIndex;
  final AppMode? modeOverride;
  final String? macAddress;
  const VerificationScreen({
    super.key,
    this.sectionIndex = 0,
    this.modeOverride,
    this.macAddress,
  });
  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isFrontCamera = true;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;
  bool _torchOn = false;

  final PillOnTongueService _service = PillOnTongueService();
  PillOnTongueResult _lastResult = PillOnTongueResult.empty();
  Size _imageSize = const Size(480, 640);
  bool _isProcessing = false;
  /// Wall-clock timestamp of the last frame we processed. Used to detect when
  /// the camera plugin pauses the image stream during recording so we can
  /// hide the (now stale) PillPainter overlay.
  DateTime? _lastFrameTime;

  int _frameCount = 0;
  int _facePresentFrames = 0;
  int _mouthOpenFrames = 0;
  int _pillOnTongueFrames = 0;
  DetectionPhase _highestPhaseReached = DetectionPhase.noFace;

  bool _consentEnabled = false;
  bool _recording = false;
  String? _recordedLocalPath;
  Timer? _recordingTimeoutTimer;
  DateTime? _recordingStartedAt;
  static const Duration _recordingMaxDuration = Duration(seconds: 15);

  bool _uploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';

  final String _sessionId = const Uuid().v4();
  bool _videoUploaded = false;
  bool _completed = false;
  String? _statusMessage;

  final CloudVerificationService _cloudService = CloudVerificationService();
  final AccuracyScoringEngine _scoringEngine = AccuracyScoringEngine();

  AppMode get _appMode => widget.modeOverride ?? modeProvider.value;
  String get _deviceId =>
      widget.macAddress ??
      FirebaseAuth.instance.currentUser?.uid ??
      'unknown_device';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _consentEnabled = await ConsentService.isVideoConsentEnabled();
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _lastResult = PillOnTongueResult.empty());
      return;
    }
    await _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final front =
          cameras.where((c) => c.lensDirection == CameraLensDirection.front);
      final ordered = [...front, ...cameras].toSet().toList();
      for (final camera in ordered) {
        try {
          final controller = CameraController(
            camera,
            ResolutionPreset.medium,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.nv21,
          );
          await controller.initialize().timeout(const Duration(seconds: 10));
          if (!mounted) {
            await controller.dispose();
            return;
          }
          _controller = controller;
          _isFrontCamera = camera.lensDirection == CameraLensDirection.front;
          _rotation = InputImageRotationValue.fromRawValue(
                  camera.sensorOrientation) ??
              InputImageRotation.rotation0deg;
          if (mounted) setState(() => _isCameraInitialized = true);
          await _controller!.startImageStream(_onFrame);
          return;
        } catch (e) {
          debugPrint('[VerificationScreen] Camera ${camera.name} failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[VerificationScreen] Camera init error: $e');
    }
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_isProcessing || _completed) return;
    _isProcessing = true;
    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;
      final result = await _service.processFrame(image, inputImage);
      _frameCount++;
      _lastFrameTime = DateTime.now();
      if (result.face != null) _facePresentFrames++;
      switch (result.phase) {
        case DetectionPhase.mouthOpen:
        case DetectionPhase.pillOnTongue:
        case DetectionPhase.mouthClosedWithPill:
        case DetectionPhase.drinking:
        case DetectionPhase.mouthReopened:
          _mouthOpenFrames++;
          break;
        default:
          break;
      }
      if (result.phase == DetectionPhase.pillOnTongue ||
          result.phase == DetectionPhase.mouthClosedWithPill) {
        _pillOnTongueFrames++;
      }
      if (result.phase.index > _highestPhaseReached.index) {
        _highestPhaseReached = result.phase;
      }
      // Trigger recording only AFTER the pill is confirmed on the tongue —
      // this guarantees the recording captures a meaningful moment (pill
      // placement → mouth close → drink → swallow), not just an empty
      // open mouth.
      if (!_recording &&
          !_videoUploaded &&
          _consentEnabled &&
          result.phase == DetectionPhase.pillOnTongue) {
        _startRecording();
      }
      if (result.phase == DetectionPhase.swallowConfirmed && !_completed) {
        _finalizeSuccess();
      }
      if (mounted) {
        setState(() {
          _lastResult = result;
          _imageSize = Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (e) {
      debugPrint('[VerificationScreen] Detection error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;
    if (image.format.group != ImageFormatGroup.nv21) return null;
    if (image.planes.isEmpty) return null;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  // Concurrent strategy: image stream and video recording run in parallel.
  // Modern Android phones deliver frames at reduced rate during recording so
  // detection keeps progressing. If a device pauses the stream, the staleness
  // detector below hides the frozen overlay and the post-recording grace
  // period in _onTimeout gives detection a chance to catch up.
  Future<void> _startRecording() async {
    if (_recording || _videoUploaded || _controller == null) return;
    if (_controller!.value.isRecordingVideo) return;
    try {
      // Concurrent mode: do NOT stop the image stream. Modern Android phones
      // (S20+, S22, S23 etc.) deliver frames at reduced rate during recording,
      // which keeps detection alive. On devices that pause the stream the
      // staleness detector below hides the (frozen) painter, so the user
      // doesn't see misleading overlays.
      await _controller!.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordingStartedAt = DateTime.now();
        _statusMessage = 'Kayıt başladı — hapı yutun ve su için';
      });
      _recordingTimeoutTimer?.cancel();
      _recordingTimeoutTimer = Timer(_recordingMaxDuration, _onTimeout);
    } catch (e) {
      debugPrint('[VerificationScreen] startRecording failed: $e');
      if (mounted) setState(() => _recording = false);
    }
  }

  Future<String?> _stopRecording() async {
    if (!_recording || _controller == null) return null;
    if (!_controller!.value.isRecordingVideo) return null;
    try {
      final XFile file = await _controller!.stopVideoRecording();
      _recordingTimeoutTimer?.cancel();
      _recordedLocalPath = file.path;
      if (mounted) setState(() => _recording = false);
      // If the camera plugin paused the stream during recording (some devices
      // do), restart it so swallow detection can finish post-recording.
      await _resumeImageStreamIfNeeded();
      return file.path;
    } catch (e) {
      debugPrint('[VerificationScreen] stopRecording failed: $e');
      if (mounted) setState(() => _recording = false);
      await _resumeImageStreamIfNeeded();
      return null;
    }
  }

  Future<void> _resumeImageStreamIfNeeded() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isRecordingVideo) return;
    if (c.value.isStreamingImages) return;
    if (_completed) return;
    try {
      await c.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('[VerificationScreen] resume stream failed: $e');
    }
  }

  Future<void> _discardLocalRecording() async {
    final path = _recordedLocalPath;
    _recordedLocalPath = null;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _toggleTorch() async {
    final c = _controller;
    if (c == null) return;
    _torchOn = !_torchOn;
    try {
      await c.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _finalizeSuccess() async {
    if (_completed) return;
    _completed = true;
    if (mounted) setState(() => _statusMessage = 'Yutma onaylandı.');
    final localPath = await _stopRecording();
    await _saveAndUpload(
      localPath: localPath,
      userConfirmed: true,
      detectionConfirmed: true,
    );
    if (mounted) setState(() => _statusMessage = 'Doğrulama başarılı.');
  }

  Future<void> _onTimeout() async {
    if (_completed) return;
    if (mounted) setState(() => _statusMessage = 'Kayıt bitti — yutma doğrulanıyor...');
    await _stopRecording();
    if (!mounted) return;
    // Grace period: give the resumed detection up to 10 seconds to catch
    // DetectionPhase.swallowConfirmed before falling back to the user dialog.
    final graceUntil = DateTime.now().add(const Duration(seconds: 10));
    while (mounted && !_completed && DateTime.now().isBefore(graceUntil)) {
      if (_lastResult.phase == DetectionPhase.swallowConfirmed) {
        // _finalizeSuccess will be called from _onFrame
        return;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted || _completed) return;
    if (mounted) setState(() => _statusMessage = 'Otomatik doğrulanamadı.');
    final tookIt = await _showTimeoutDialog();
    if (!mounted) return;
    if (tookIt == true) {
      _completed = true;
      await _saveAndUpload(
        localPath: _recordedLocalPath,
        userConfirmed: true,
        detectionConfirmed: false,
      );
      if (mounted) setState(() => _statusMessage = 'Onayınız kaydedildi.');
    } else {
      await _discardLocalRecording();
      _resetForRetry();
    }
  }

  Future<bool?> _showTimeoutDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.timer_off_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Süre Doldu'),
          ],
        ),
        content: const Text(
          '30 saniye içinde yutma tespit edilemedi. '
          'İlacı aldığınızı onaylıyor musunuz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hayır, içemedim'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.skyBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Evet, içtim'),
          ),
        ],
      ),
    );
  }

  void _resetForRetry() {
    _frameCount = 0;
    _facePresentFrames = 0;
    _mouthOpenFrames = 0;
    _pillOnTongueFrames = 0;
    _highestPhaseReached = DetectionPhase.noFace;
    _service.reset();
    if (mounted) setState(() => _statusMessage = 'Tekrar deneyin.');
  }

  Future<String> _compressVideo(String sourcePath) async {
    if (mounted) {
      setState(() {
        _uploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Video sıkıştırılıyor...';
      });
    }
    try {
      final sub = VideoCompress.compressProgress$.subscribe((p) {
        if (!mounted) return;
        setState(() => _uploadProgress = (p / 100.0 * 0.5).clamp(0.0, 0.5));
      });
      final info = await VideoCompress.compressVideo(
        sourcePath,
        quality: VideoQuality.LowQuality,
        deleteOrigin: false,
        includeAudio: false,
      );
      sub.unsubscribe();
      final compressedPath = info?.path;
      if (compressedPath == null || compressedPath.isEmpty) return sourcePath;
      try {
        final f = File(sourcePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return compressedPath;
    } catch (e) {
      debugPrint('[VerificationScreen] Compression failed: $e');
      return sourcePath;
    }
  }

  Future<void> _saveAndUpload({
    required String? localPath,
    required bool userConfirmed,
    required bool detectionConfirmed,
  }) async {
    final score = _computeScore(detectionConfirmed: detectionConfirmed);
    final classification = _scoringEngine.classify(score);
    String footageUrl = '';
    String? storagePath;
    if (_consentEnabled && localPath != null && !_videoUploaded) {
      final pathToUpload = await _compressVideo(localPath);
      if (mounted) setState(() => _uploadStatus = 'Sunucuya yükleniyor...');
      try {
        final upload = await _cloudService.uploadVideo(
          deviceId: _deviceId,
          localPath: pathToUpload,
          onProgress: (p) {
            if (!mounted) return;
            setState(() =>
                _uploadProgress = (0.5 + p * 0.5).clamp(0.0, 1.0));
          },
        );
        footageUrl = upload.downloadUrl;
        storagePath = upload.storagePath;
        _videoUploaded = true;
      } catch (e) {
        debugPrint('[VerificationScreen] Upload failed: $e');
        if (mounted) setState(() => _uploadStatus = 'Yükleme başarısız.');
      } finally {
        try {
          final f = File(pathToUpload);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    if (mounted && _consentEnabled && localPath != null) {
      setState(() => _uploadStatus = 'Doğrulama kaydı yazılıyor...');
    }
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId != null) {
      final result = vr.VerificationResult(
        id: _sessionId,
        accuracyScore: score,
        classification: _mapClassification(classification),
        presenceDetected: _facePresentFrames > 0,
        appMode: _appMode,
        subScores: {
          'pill': _frameCount == 0 ? 0.0 : _pillOnTongueFrames / _frameCount,
          'mouth': _frameCount == 0 ? 0.0 : _mouthOpenFrames / _frameCount,
          'detectionConfirmed': detectionConfirmed ? 1.0 : 0.0,
          'userConfirmed': userConfirmed ? 1.0 : 0.0,
        },
        footageUrl: footageUrl,
        sectionIndex: widget.sectionIndex,
        timestamp: DateTime.now(),
      );
      try {
        await _cloudService.save(userId, result);
      } catch (_) {}
      if (widget.macAddress != null && widget.macAddress!.isNotEmpty) {
        try {
          await _cloudService.saveForDevice(
            macAddress: widget.macAddress!,
            result: result,
            extraData: {
              'storagePath': storagePath,
              'sessionId': _sessionId,
              'deviceId': _deviceId,
              'detectionConfirmed': detectionConfirmed,
              'userConfirmed': userConfirmed,
              'highestPhase': _highestPhaseReached.name,
            },
          );
        } catch (_) {}
      }
    }
    if (mounted) {
      setState(() {
        _uploading = false;
        _uploadStatus = '';
      });
    }
  }

  double _computeScore({required bool detectionConfirmed}) {
    if (_frameCount == 0) return 0.0;
    final pillRatio = _pillOnTongueFrames / _frameCount;
    final mouthRatio = _mouthOpenFrames / _frameCount;
    return _scoringEngine.calculate(
      mode: _appMode == AppMode.device
          ? ScoringMode.withDevice
          : ScoringMode.deviceFree,
      pill: pillRatio.clamp(0.0, 1.0),
      lip: pillRatio.clamp(0.0, 1.0),
      mouth: mouthRatio.clamp(0.0, 1.0),
      timing: detectionConfirmed ? 1.0 : 0.4,
    );
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

  Color _phaseAccent(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
      case DetectionPhase.swallowFailed:
        return Colors.redAccent;
      case DetectionPhase.faceDetected:
        return Colors.orange;
      case DetectionPhase.mouthOpen:
      case DetectionPhase.mouthReopened:
      case DetectionPhase.drinking:
        return AppColors.skyBlue;
      case DetectionPhase.pillOnTongue:
      case DetectionPhase.mouthClosedWithPill:
      case DetectionPhase.swallowConfirmed:
        return AppColors.turquoise;
      case DetectionPhase.timeoutExpired:
        return Colors.grey;
    }
  }

  IconData _phaseIcon(DetectionPhase phase) {
    switch (phase) {
      case DetectionPhase.noFace:
        return Icons.face_retouching_off_rounded;
      case DetectionPhase.faceDetected:
        return Icons.face_rounded;
      case DetectionPhase.mouthOpen:
        return Icons.sentiment_satisfied_alt_rounded;
      case DetectionPhase.pillOnTongue:
        return Icons.medication_rounded;
      case DetectionPhase.mouthClosedWithPill:
        return Icons.no_food_rounded;
      case DetectionPhase.drinking:
        return Icons.local_drink_rounded;
      case DetectionPhase.mouthReopened:
        return Icons.sentiment_neutral_rounded;
      case DetectionPhase.swallowConfirmed:
        return Icons.verified_rounded;
      case DetectionPhase.swallowFailed:
        return Icons.error_outline_rounded;
      case DetectionPhase.timeoutExpired:
        return Icons.timer_off_rounded;
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
        return 'Ağız Kapandı';
      case DetectionPhase.drinking:
        return 'Su İçiliyor';
      case DetectionPhase.mouthReopened:
        return 'Ağız Yeniden Açıldı';
      case DetectionPhase.swallowConfirmed:
        return 'Yutma Onaylandı';
      case DetectionPhase.swallowFailed:
        return 'Yutma Başarısız';
      case DetectionPhase.timeoutExpired:
        return 'Süre Doldu';
    }
  }

  bool _stepReached(DetectionPhase phase, int step) {
    int reached;
    switch (phase) {
      case DetectionPhase.noFace:
      case DetectionPhase.timeoutExpired:
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
      case DetectionPhase.swallowFailed:
        reached = 6;
        break;
    }
    return reached >= step;
  }

  @override
  Widget build(BuildContext context) {
    final phase = _lastResult.phase;
    final accent = _phaseAccent(phase);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('İlaç Doğrulama',
            style: GoogleFonts.inter(
                fontWeight: FontWeight.w800, color: AppColors.deepSea)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.deepSea),
        actions: [
          IconButton(
            icon: Icon(
                _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                color: AppColors.deepSea),
            onPressed: _isCameraInitialized ? _toggleTorch : null,
          ),
          IconButton(
            icon:
                const Icon(Icons.refresh_rounded, color: AppColors.deepSea),
            onPressed: _completed
                ? null
                : () {
                    _service.reset();
                    setState(() {
                      _lastResult = PillOnTongueResult.empty();
                      _frameCount = 0;
                      _facePresentFrames = 0;
                      _mouthOpenFrames = 0;
                      _pillOnTongueFrames = 0;
                      _highestPhaseReached = DetectionPhase.noFace;
                    });
                  },
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  flex: 7,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: _CameraCard(
                      controller: _controller,
                      isInitialized: _isCameraInitialized,
                      isFrontCamera: _isFrontCamera,
                      lastResult: _lastResult,
                      imageSize: _imageSize,
                      rotation: _rotation,
                      accent: accent,
                      phaseLabel: _phaseLabel(phase),
                      phaseIcon: _phaseIcon(phase),
                      recording: _recording,
                      recordingStartedAt: _recordingStartedAt,
                      consentEnabled: _consentEnabled,
                      lastFrameTime: _lastFrameTime,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      children: [
                        _GuidanceCard(
                          accent: accent,
                          icon: _phaseIcon(phase),
                          title: _statusMessage ?? _phaseLabel(phase),
                          subtitle: _recording
                              ? 'Detection duraklatıldı (kayıt sürüyor) — '
                                  'lütfen ilacınızı alıp yutun'
                              : _lastResult.guidance,
                        ),
                        const SizedBox(height: 8),
                        _StepTracker(
                          steps: const [
                            'Yüz',
                            'Ağız',
                            'Hap',
                            'Kapat',
                            'Su',
                            'Yut'
                          ],
                          stepReached: (i) => _stepReached(phase, i),
                          phase: phase,
                        ),
                        if (_completed) ...[
                          const SizedBox(height: 12),
                          _CompleteButton(
                              onPressed: () => Navigator.of(context).pop()),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_uploading)
            _UploadOverlay(
                progress: _uploadProgress, status: _uploadStatus),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _recordingTimeoutTimer?.cancel();
    if (_controller?.value.isStreamingImages ?? false) {
      _controller?.stopImageStream().catchError((_) {});
    }
    if (_controller?.value.isRecordingVideo ?? false) {
      _controller?.stopVideoRecording().catchError((_) => XFile(''));
    }
    _controller?.dispose();
    _service.dispose();
    super.dispose();
  }
}

class _CameraCard extends StatelessWidget {
  final CameraController? controller;
  final bool isInitialized;
  final bool isFrontCamera;
  final PillOnTongueResult lastResult;
  final Size imageSize;
  final InputImageRotation rotation;
  final Color accent;
  final String phaseLabel;
  final IconData phaseIcon;
  final bool recording;
  final DateTime? recordingStartedAt;
  final bool consentEnabled;
  final DateTime? lastFrameTime;

  const _CameraCard({
    required this.controller,
    required this.isInitialized,
    required this.isFrontCamera,
    required this.lastResult,
    required this.imageSize,
    required this.rotation,
    required this.accent,
    required this.phaseLabel,
    required this.phaseIcon,
    required this.recording,
    required this.recordingStartedAt,
    required this.consentEnabled,
    required this.lastFrameTime,
  });

  bool get _framesAreStale {
    if (lastFrameTime == null) return true;
    return DateTime.now().difference(lastFrameTime!) >
        const Duration(milliseconds: 1500);
  }

  bool get _rotated90or270 =>
      rotation == InputImageRotation.rotation90deg ||
      rotation == InputImageRotation.rotation270deg;

  @override
  Widget build(BuildContext context) {
    if (!isInitialized || controller == null) {
      return _shell(
          child: const Center(
              child: CircularProgressIndicator(color: AppColors.skyBlue)));
    }
    final preview = controller!.value.previewSize;
    if (preview == null) {
      return _shell(
          child: const Center(child: CircularProgressIndicator()));
    }
    final w = _rotated90or270 ? preview.height : preview.width;
    final h = _rotated90or270 ? preview.width : preview.height;
    final aspect = w / h;

    return _shell(
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(controller!),
              // Painter çizilir EĞER:
              //   - face algılanmış AND
              //   - frame'ler güncel (< 1.5s eski) — yani concurrent çalışıyor
              // Bu sayede recording sırasında frame'ler gelmeye devam ediyorsa
              // dudak takibi canlı görünür; durmuşsa donmuş overlay gizlenir.
              if (lastResult.face != null && !_framesAreStale)
                CustomPaint(
                  painter: PillPainter(
                    result: lastResult,
                    imageSize: imageSize,
                    rotation: rotation,
                    isFrontCamera: isFrontCamera,
                  ),
                ),
              // Recording sırasında frame'ler donmuşsa "kayıt sürüyor" göster
              if (recording && _framesAreStale)
                const _RecordingDimOverlay(),
              if (recording && recordingStartedAt != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: _RecPill(startedAt: recordingStartedAt!),
                ),
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(phaseIcon, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        recording ? 'KAYIT' : phaseLabel,
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!consentEnabled)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade400,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'KVKK onayı yok — kayıt yapılmıyor.',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shell({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blueGrey.shade50, width: 1),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: child,
      ),
    );
  }
}

/// Recording sırasında ekrana hafif karartma + büyük kayıt animasyonu.
/// Painter gizlendiği için kullanıcı "donmuş takip" yerine bunu görür.
class _RecordingDimOverlay extends StatefulWidget {
  const _RecordingDimOverlay();
  @override
  State<_RecordingDimOverlay> createState() => _RecordingDimOverlayState();
}

class _RecordingDimOverlayState extends State<_RecordingDimOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.18),
          child: Center(
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.05).animate(
                CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.fiber_manual_record,
                        color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'KAYIT SÜRÜYOR',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GuidanceCard extends StatelessWidget {
  final Color accent;
  final IconData icon;
  final String title;
  final String subtitle;
  const _GuidanceCard({
    required this.accent,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.deepSea,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: const Color(0xFF475569),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTracker extends StatelessWidget {
  final List<String> steps;
  final bool Function(int) stepReached;
  final DetectionPhase phase;
  const _StepTracker({
    required this.steps,
    required this.stepReached,
    required this.phase,
  });

  Color _stepColor(int i) {
    final palette = const [
      Colors.orange,
      AppColors.skyBlue,
      AppColors.turquoise,
      Colors.amber,
      Colors.lightBlue,
      AppColors.turquoise,
    ];
    if (i == 6 && phase == DetectionPhase.swallowFailed) {
      return Colors.redAccent;
    }
    return palette[i - 1];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: Row(
        children: [
          for (int i = 1; i <= steps.length; i++) ...[
            _StepDot(
              label: steps[i - 1],
              active: stepReached(i),
              color: _stepColor(i),
            ),
            if (i < steps.length) _StepLine(active: stepReached(i + 1)),
          ],
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  const _StepDot({
    required this.label,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? color : Colors.blueGrey.shade100,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 5,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: active
              ? const Icon(Icons.check_rounded,
                  color: Colors.white, size: 14)
              : null,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: GoogleFonts.inter(
            color: active ? color : Colors.blueGrey.shade300,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  final bool active;
  const _StepLine({required this.active});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        height: 2,
        margin: const EdgeInsets.only(bottom: 14, left: 1, right: 1),
        color: active ? AppColors.skyBlue : Colors.blueGrey.shade100,
      ),
    );
  }
}

class _CompleteButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _CompleteButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [AppColors.skyBlue, AppColors.deepSea],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Tamamla',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
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

class _RecPill extends StatefulWidget {
  final DateTime startedAt;
  const _RecPill({required this.startedAt});
  @override
  State<_RecPill> createState() => _RecPillState();
}

class _RecPillState extends State<_RecPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _t = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = DateTime.now().difference(widget.startedAt).inSeconds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _ctrl,
            child: const Icon(Icons.fiber_manual_record,
                color: Colors.redAccent, size: 12),
          ),
          const SizedBox(width: 5),
          Text(
            'REC ${elapsed}s/30s',
            style: GoogleFonts.inter(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadOverlay extends StatelessWidget {
  final double progress;
  final String status;
  const _UploadOverlay({required this.progress, required this.status});

  @override
  Widget build(BuildContext context) {
    final pct = (progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.deepSea.withValues(alpha: 0.65),
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 96,
                        height: 96,
                        child: CircularProgressIndicator(
                          value: progress > 0 ? progress : null,
                          strokeWidth: 6,
                          backgroundColor:
                              AppColors.skyBlue.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.skyBlue),
                        ),
                      ),
                      Text(
                        '$pct%',
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.deepSea,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Video İşleniyor',
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.deepSea,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  status.isEmpty ? 'Lütfen bekleyin...' : status,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: const Color(0xFF475569),
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
