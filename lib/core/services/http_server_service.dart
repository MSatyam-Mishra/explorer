import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';

class HttpServerService {
  HttpServer? _server;
  String? _servingUrl;

  bool get isRunning => _server != null;
  String? get servingUrl => _servingUrl;

  Future<String> startServer(String directoryPath, {int port = 8080}) async {
    if (_server != null) {
      await stopServer();
    }

    // Create a handler that serves static files from the directory
    var handler = createStaticHandler(
      directoryPath,
      defaultDocument: 'index.html',
      listDirectories: true,
    );

    // Bind to any IPv4 adapter
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);

    // Get local IP address to show to user
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    String ip = 'localhost';
    try {
      // Logic to find a 192.168... or 10... address usually main wifi
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            ip = addr.address;
            break;
          }
        }
      }
    } catch (_) {}

    _servingUrl = 'http://$ip:${_server!.port}';
    print('Serving at $_servingUrl');
    return _servingUrl!;
  }

  Future<void> stopServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _servingUrl = null;
      print('Server stopped');
    }
  }
}
