import 'package:camera/camera.dart';
import 'package:medTrackPlus/beta/models/cv_frame_data.dart';

/// Processes a raw camera frame and returns structured CV detections.
/// Implementations: MockCVProcessor (beta), MLKitCVProcessor (production).
abstract class CVProcessor {
  Future<CVFrameData> processFrame(CameraImage frame);
  Future<void> dispose();
}
