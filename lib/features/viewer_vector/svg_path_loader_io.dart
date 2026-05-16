import 'dart:io';

Future<String> loadSvgFromPath(String path) => File(path).readAsString();
