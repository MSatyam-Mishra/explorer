import 'dart:io';

class RootService {
  /// Checks if the device is rooted by verifying if `su` binary exists.
  Future<bool> isRooted() async {
    try {
      final result = await Process.run('which', ['su']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Requests root access by running a dummy command with `su`.
  /// Returns true if permission is granted.
  Future<bool> requestRootAccess() async {
    try {
      final result = await Process.run('su', [
        '-c',
        'echo root_access_granted',
      ]);
      return result.exitCode == 0 &&
          result.stdout.toString().contains('root_access_granted');
    } catch (e) {
      return false;
    }
  }

  /// Runs a command with root privileges using `su`.
  Future<ProcessResult> runRootCommand(String command) async {
    // We wrap the command in single quotes to pass it to su -c
    // Note: Complex quoting inside 'command' might need better handling.
    return await Process.run('su', ['-c', command]);
  }

  /// Runs a command with root privileges and returns the process for stream handling.
  Future<Process> startRootCommand(String command) async {
    return await Process.start('su', ['-c', command]);
  }
}
