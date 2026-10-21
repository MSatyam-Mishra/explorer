import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

enum UnlockResult {
  unlocked,

  /// Cancelled or wrong.
  failed,

  /// The device has no screen lock, so there's nothing to check.
  noScreenLock,
}

class AuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Asks for the fingerprint, face, PIN, pattern or password that unlocks
  /// the device.
  Future<UnlockResult> unlock({required String reason}) async {
    try {
      if (!await _auth.isDeviceSupported()) return UnlockResult.noScreenLock;
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true),
      );
      return ok ? UnlockResult.unlocked : UnlockResult.failed;
    } on PlatformException catch (e) {
      debugPrint('Unlock failed: ${e.code} ${e.message}');
      return switch (e.code) {
        auth_error.passcodeNotSet ||
        auth_error.notEnrolled ||
        auth_error.notAvailable =>
          UnlockResult.noScreenLock,
        _ => UnlockResult.failed,
      };
    } on MissingPluginException {
      return UnlockResult.noScreenLock;
    }
  }
}
