import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:medTrackPlus/main.dart';
import 'package:video_player/video_player.dart';

class RelativeReviewScreen extends StatefulWidget {
  final String macAddress;
  final String verificationId;

  const RelativeReviewScreen({
    super.key,
    required this.macAddress,
    required this.verificationId,
  });

  @override
  State<RelativeReviewScreen> createState() => _RelativeReviewScreenState();
}

class _RelativeReviewScreenState extends State<RelativeReviewScreen> {
  Map<String, dynamic>? _verification;
  bool _loading = true;
  String? _error;

  VideoPlayerController? _videoController;
  bool _videoInitialized = false;
  String? _videoError;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadVerification();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _loadVerification() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('dispenser').doc(widget.macAddress)
          .collection('verifications').doc(widget.verificationId)
          .get();

      if (doc.exists) {
        setState(() {
          _verification = doc.data();
          _loading = false;
        });
        _initVideoIfAvailable();
      } else {
        setState(() {
          _loading = false;
          _error = 'Verification not found';
        });
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load verification: $e';
      });
    }
  }

  void _initVideoIfAvailable() {
    final url = _verification?['footageUrl'] ?? '';
    if (url.isEmpty) return;

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url))
      ..initialize().then((_) {
        if (mounted) setState(() => _videoInitialized = true);
      }).catchError((e) {
        if (mounted) setState(() => _videoError = 'Video could not be loaded');
      });
  }

  Future<void> _submitDecision(String decision) async {
    setState(() => _submitting = true);
    try {
      await FirebaseFirestore.instance
          .collection('dispenser').doc(widget.macAddress)
          .collection('verifications').doc(widget.verificationId)
          .update({'review_decision': decision});

      if (mounted) {
        setState(() {
          _verification!['review_decision'] = decision;
          _submitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(decision == 'approved' ? 'Approved successfully' : 'Denied'),
            backgroundColor: decision == 'approved' ? Colors.green : Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Verification Review'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.deepSea),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.skyBlue))
          : _error != null
              ? _buildErrorState(_error!)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildVideoArea(),
                      const SizedBox(height: 20),
                      _buildClassificationBadge(),
                      const SizedBox(height: 16),
                      _buildModeIndicator(),
                      const SizedBox(height: 16),
                      _buildAccuracySection(),
                      const SizedBox(height: 16),
                      _buildPhaseIndicators(),
                      const SizedBox(height: 16),
                      _buildDetailsPanel(),
                      const SizedBox(height: 24),
                      _buildActionButtons(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildErrorState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 20),
          Text(message, style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () {
              setState(() { _loading = true; _error = null; });
              _loadVerification();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.skyBlue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    final footageUrl = _verification?['footageUrl'] ?? '';
    final isDeviceFree = (_verification?['appMode'] ?? '') == 'deviceFree';

    if (footageUrl.isEmpty) {
      return Container(
        height: 180,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off_rounded, size: 48, color: Colors.white.withOpacity(0.25)),
              const SizedBox(height: 8),
              Text(
                isDeviceFree ? 'No video in device-free mode' : 'No video recording',
                style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (_videoError != null) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.broken_image_rounded, size: 48, color: Colors.redAccent),
              const SizedBox(height: 8),
              Text(_videoError!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    if (!_videoInitialized) {
      return Container(
        height: 220,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Center(child: CircularProgressIndicator(color: Colors.white54)),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        color: const Color(0xFF1A1A2E),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),
            VideoProgressIndicator(
              _videoController!,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: AppColors.turquoise,
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white12,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => _videoController!.seekTo(Duration.zero),
                    icon: const Icon(Icons.replay, color: Colors.white70, size: 22),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _videoController!.value.isPlaying
                            ? _videoController!.pause()
                            : _videoController!.play();
                      });
                    },
                    icon: Icon(
                      _videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white, size: 32,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClassificationBadge() {
    final classification = _verification?['classification'] ?? 'unknown';
    final reviewDecision = _verification?['review_decision'];

    Color classColor;
    IconData classIcon;
    String classText;

    switch (classification) {
      case 'success':
        classColor = Colors.green;
        classIcon = Icons.check_circle_rounded;
        classText = 'Success';
        break;
      case 'suspicious':
        classColor = Colors.orange;
        classIcon = Icons.warning_amber_rounded;
        classText = 'Suspicious';
        break;
      case 'rejected':
        classColor = Colors.redAccent;
        classIcon = Icons.cancel_rounded;
        classText = 'Rejected';
        break;
      default:
        classColor = Colors.grey;
        classIcon = Icons.help_outline_rounded;
        classText = 'Unknown';
    }

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: classColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(classIcon, color: classColor, size: 20),
              const SizedBox(width: 6),
              Text(classText, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: classColor)),
            ],
          ),
        ),
        const Spacer(),
        if (reviewDecision != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: reviewDecision == 'approved' ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              reviewDecision == 'approved' ? 'Approved' : 'Denied',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: reviewDecision == 'approved' ? Colors.green : Colors.redAccent,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildModeIndicator() {
    final appMode = _verification?['appMode'] ?? 'device';
    final isDeviceFree = appMode == 'deviceFree';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDeviceFree ? Colors.purple.withOpacity(0.08) : AppColors.skyBlue.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDeviceFree ? Colors.purple.withOpacity(0.2) : AppColors.skyBlue.withOpacity(0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isDeviceFree ? Icons.phone_android : Icons.devices_rounded,
            color: isDeviceFree ? Colors.purple : AppColors.skyBlue,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            isDeviceFree ? 'Device-Free Mode' : 'Device Mode',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: isDeviceFree ? Colors.purple : AppColors.skyBlue,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          if (!isDeviceFree)
            Text(widget.macAddress, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildAccuracySection() {
    final score = (_verification?['accuracyScore'] ?? 0).toDouble();
    final Map<String, dynamic> subScoresRaw = Map<String, dynamic>.from(_verification?['subScores'] ?? {});

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, color: _scoreColor(score), size: 22),
              const SizedBox(width: 8),
              const Text('Accuracy Score', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.deepSea)),
              const Spacer(),
              Text('${(score * 100).toStringAsFixed(1)}%',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: _scoreColor(score))),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: score.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(_scoreColor(score)),
            ),
          ),
          if (subScoresRaw.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Sub-Scores', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 10),
            ...subScoresRaw.entries.map((e) {
              final val = (e.value as num).toDouble();
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_subScoreIcon(e.key), size: 16, color: _scoreColor(val)),
                        const SizedBox(width: 6),
                        Text(_subScoreLabel(e.key),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.deepSea)),
                        const Spacer(),
                        Text('${(val * 100).toStringAsFixed(0)}%',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _scoreColor(val))),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: val.clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation(_scoreColor(val)),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Color _scoreColor(double score) {
    if (score >= 0.7) return Colors.green;
    if (score >= 0.4) return Colors.orange;
    return Colors.redAccent;
  }

  IconData _subScoreIcon(String key) {
    switch (key) {
      case 'pillDetection': return Icons.medication_rounded;
      case 'mouthVerification': return Icons.face_rounded;
      case 'presenceScore': return Icons.person_search_rounded;
      case 'speedScore': return Icons.timer_rounded;
      default: return Icons.analytics_rounded;
    }
  }

  String _subScoreLabel(String key) {
    switch (key) {
      case 'pillDetection': return 'Pill Detection';
      case 'mouthVerification': return 'Mouth Verification';
      case 'presenceScore': return 'Presence Detection';
      case 'speedScore': return 'Speed Score';
      default:
        return key.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m.group(1)} ${m.group(2)}');
    }
  }

  Widget _buildPhaseIndicators() {
    final Map<String, dynamic> subScores = Map<String, dynamic>.from(_verification?['subScores'] ?? {});
    if (subScores.isEmpty) return const SizedBox.shrink();

    final phases = [
      _PhaseInfo('Pill Detection', 'pillDetection', Icons.medication_rounded),
      _PhaseInfo('Tracking to Mouth', 'speedScore', Icons.trending_up_rounded),
      _PhaseInfo('Mouth Verification', 'mouthVerification', Icons.face_rounded),
      _PhaseInfo('Presence Check', 'presenceScore', Icons.person_search_rounded),
    ];

    final activePhases = phases.where((p) => subScores.containsKey(p.scoreKey)).toList();
    if (activePhases.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Phase Status', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.deepSea)),
          const SizedBox(height: 12),
          ...activePhases.map((phase) {
            final val = (subScores[phase.scoreKey] as num).toDouble();
            final passed = val >= 0.5;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: (passed ? Colors.green : Colors.redAccent).withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      passed ? Icons.check_rounded : Icons.close_rounded,
                      color: passed ? Colors.green : Colors.redAccent,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(phase.label,
                        style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500,
                          color: passed ? AppColors.deepSea : Colors.redAccent,
                        )),
                  ),
                  Icon(phase.icon, size: 18, color: passed ? Colors.green : Colors.redAccent),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDetailsPanel() {
    final data = _verification!;
    final section = data['sectionIndex'] ?? data['section'] ?? 0;
    final hasDevice = data['hasDevice'] ?? false;
    final presence = data['presenceDetected'] ?? false;
    final timestamp = data['timestamp'] ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50),
      ),
      child: Column(
        children: [
          _detailRow(Icons.medication_rounded, 'Section', 'Section ${section.toString().replaceAll('.0', '')}'),
          _divider(),
          _detailRow(Icons.devices_rounded, 'With Device', hasDevice ? 'Yes' : 'No'),
          _divider(),
          _detailRow(Icons.person_rounded, 'Presence', presence ? 'Yes' : 'No'),
          _divider(),
          _detailRow(Icons.access_time_rounded, 'Timestamp', _formatTimestamp(timestamp)),
        ],
      ),
    );
  }

  Widget _divider() => Divider(height: 1, color: Colors.blueGrey.shade50);

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.skyBlue.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppColors.skyBlue, size: 18),
          ),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 14, fontWeight: FontWeight.w500)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.deepSea)),
        ],
      ),
    );
  }

  String _formatTimestamp(dynamic ts) {
    try {
      if (ts is String && ts.isNotEmpty) {
        final dt = DateTime.parse(ts).toLocal();
        return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      if (ts is Timestamp) {
        final dt = ts.toDate().toLocal();
        return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
    } catch (_) {}
    return '-';
  }

  Widget _buildActionButtons() {
    final reviewDecision = _verification?['review_decision'];
    if (reviewDecision != null) return const SizedBox.shrink();

    final classification = _verification?['classification'] ?? '';
    if (classification == 'success') return const SizedBox.shrink();

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _submitting ? null : () => _confirmAction('approved'),
            icon: const Icon(Icons.check_circle_outline, size: 20),
            label: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.turquoise,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _submitting ? null : () => _confirmAction('denied'),
            icon: const Icon(Icons.highlight_off_rounded, size: 20),
            label: const Text('Deny', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    );
  }

  void _confirmAction(String decision) {
    final isApprove = decision == 'approved';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isApprove ? 'Approve Verification?' : 'Deny Verification?'),
        content: Text(isApprove
            ? 'This will confirm the medication was taken correctly.'
            : 'This will flag the verification as denied.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _submitDecision(decision);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isApprove ? AppColors.turquoise : Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: Text(isApprove ? 'Approve' : 'Deny'),
          ),
        ],
      ),
    );
  }
}

class _PhaseInfo {
  final String label;
  final String scoreKey;
  final IconData icon;
  const _PhaseInfo(this.label, this.scoreKey, this.icon);
}