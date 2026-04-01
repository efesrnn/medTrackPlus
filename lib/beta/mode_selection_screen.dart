import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:medTrackPlus/app/main_hub.dart';
import 'package:medTrackPlus/beta/enums/app_mode.dart';
import 'package:medTrackPlus/main.dart';
import 'package:medTrackPlus/beta/providers/mode_provider.dart';

class ModeSelectionScreen extends StatelessWidget {
  const ModeSelectionScreen({super.key});

  void _select(BuildContext context, AppMode mode) {
    modeProvider.setMode(mode);
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const MainHub(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How are you using\nMedTrack?',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.deepSea,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You can change this later in Settings.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppColors.deepSea.withOpacity(0.5),
                ),
              ),
              const Spacer(),
              _ModeCard(
                icon: Icons.medication_liquid_rounded,
                title: 'With Dispenser',
                subtitle: 'I have the MedTrack hardware device',
                mode: AppMode.device,
                onTap: () => _select(context, AppMode.device),
              ),
              const SizedBox(height: 16),
              _ModeCard(
                icon: Icons.smartphone_rounded,
                title: 'Device-Free',
                subtitle: 'I\'ll manage medications manually with my phone',
                mode: AppMode.deviceFree,
                onTap: () => _select(context, AppMode.deviceFree),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final AppMode mode;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.mode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.skyBlue.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepSea.withOpacity(0.07),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppColors.skyBlue, AppColors.deepSea],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepSea,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: AppColors.deepSea.withOpacity(0.55),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded,
                    color: AppColors.skyBlue, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
