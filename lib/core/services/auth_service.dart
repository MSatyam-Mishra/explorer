import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class AuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> authenticate() async {
    try {
      final bool canCheckBiometrics = await _auth.canCheckBiometrics;
      if (!canCheckBiometrics) {
        print("Biometrics not available");
        return false;
      }
      
      return await _auth.authenticate(
        localizedReason: 'Please authenticate to access your vault',
        options: const AuthenticationOptions(
          stickyAuth: true, // Keep the prompt open until success/failure
          biometricOnly: true, // Don't allow PIN/Pattern fallback from the OS
        ),
      );
    } on PlatformException catch (e) {
      print("Error during authentication: $e");
      return false;
    }
  }
}