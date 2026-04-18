import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/services/database_service.dart';

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
  final DatabaseService _db = DatabaseService();
  Map<String, dynamic>? _verification;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadVerification();
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
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('Verification load error: $e');
      setState(() => _loading = false);
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
          : _verification == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off_rounded, size: 80, color: Colors.grey.shade300),
                      const SizedBox(height: 20),
                      Text('Verification not found', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildVideoArea(),
                      const SizedBox(height: 20),
                      _buildClassificationBadge(),
                      const SizedBox(height: 16),
                      _buildDetailsPanel(),
                      const SizedBox(height: 24),
                      _buildActionButtons(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildVideoArea() {
    final footageUrl = _verification?['footageUrl'] ?? '';

    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 15, offset: const Offset(0, 6)),
        ],
      ),
      child: Center(
        child: footageUrl.isNotEmpty
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_circle_outline, size: 56, color: Colors.white70),
                  SizedBox(height: 8),
                  Text('Video Player', style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.videocam_off_rounded, size: 56, color: Colors.white.withOpacity(0.25)),
                  const SizedBox(height: 8),
                  Text('No video recording', style: TextStyle(color: Colors.white.withOpacity(0.25), fontSize: 13)),
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

  Widget _buildDetailsPanel() {
    final data = _verification!;
    final score = (data['accuracyScore'] ?? 0).toDouble();
    final section = data['sectionIndex'] ?? data['section'] ?? 0;
    final hasDevice = data['hasDevice'] ?? false;
    final timestamp = data['timestamp'] ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blueGrey.shade50, width: 1),
      ),
      child: Column(
        children: [
          _detailRow(Icons.speed_rounded, 'Accuracy Score', '${(score * 100).toStringAsFixed(1)}%'),
          _divider(),
          _detailRow(Icons.medication_rounded, 'Section', 'Section ${section.toString().replaceAll('.0', '')}'),
          _divider(),
          _detailRow(Icons.devices_rounded, 'With Device', hasDevice ? 'Yes' : 'No'),
          _divider(),
          _detailRow(Icons.access_time_rounded, 'Timestamp', _formatTimestamp(timestamp)),
        ],
      ),
    );
  }

  Widget _divider() {
    return Divider(height: 1, color: Colors.blueGrey.shade50);
  }

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

    if (reviewDecision != null) {
      return const SizedBox.shrink();
    }

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
              // TODO: Approve logic
              debugPrint('Approve tapped');
            },
            icon: const Icon(Icons.check_circle_outline, size: 20),
            label: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
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
            onPressed: () {
              // TODO: Deny logic
              debugPrint('Deny tapped');
            },
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
}