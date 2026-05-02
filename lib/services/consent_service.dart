import 'package:shared_preferences/shared_preferences.dart';

/// Tracks user consent for video verification recording (KVKK).
///
/// Storage keys:
///   - `videoConsentEnabled` (bool): user has accepted KVKK + disclaimer
///   - `videoConsentTimestamp` (int, millisSinceEpoch): when consent was given
class ConsentService {
  static const _kEnabled = 'videoConsentEnabled';
  static const _kTimestamp = 'videoConsentTimestamp';

  /// Whether the user has actively granted consent for video recording.
  static Future<bool> isVideoConsentEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? false;
  }

  /// Persists user acceptance with a timestamp.
  static Future<void> grantVideoConsent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, true);
    await prefs.setInt(_kTimestamp, DateTime.now().millisecondsSinceEpoch);
  }

  /// Revokes consent. Existing recordings (if any) are not deleted client-side;
  /// new sessions will not record.
  static Future<void> revokeVideoConsent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, false);
    await prefs.remove(_kTimestamp);
  }

  /// When consent was granted (null if never granted).
  static Future<DateTime?> consentGrantedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kTimestamp);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
}
