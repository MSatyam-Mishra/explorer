import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:filesize/filesize.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import 'package:explorer/core/services/root_service.dart';
import 'package:explorer/core/services/usb_boot_service.dart';

class UsbBootScreen extends StatefulWidget {
  const UsbBootScreen({super.key});

  @override
  State<UsbBootScreen> createState() => _UsbBootScreenState();
}

class _UsbBootScreenState extends State<UsbBootScreen> {
  final _rootService = RootService();
  final _usbService = UsbBootService();

  bool _isLoading = true;
  String? _isoPath;
  int? _isoSize;
  BlockDevice? _selectedDevice;
  List<BlockDevice> _devices = [];
  bool _isFlashing = false;

  // Progress
  double _progress = 0.0;
  String _progressStatus = '';

  Process? _flashProcess;

  @override
  void initState() {
    super.initState();
    _checkRootAndLoadDevices();
  }

  Future<void> _checkRootAndLoadDevices() async {
    setState(() => _isLoading = true);

    // 1. Check Root
    bool rooted = await _rootService.isRooted();
    if (!rooted) {
      // Try requesting
      rooted = await _rootService.requestRootAccess();
    }

    if (!rooted) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showRootErrorDialog();
      }
      return;
    }

    // 2. Load Devices
    final devices = await _usbService.getConnectableDevices();

    if (mounted) {
      setState(() {
        _devices = devices;
        _isLoading = false;
        if (devices.isNotEmpty) {
          _selectedDevice = devices.first;
        }
      });
    }
  }

  void _showRootErrorDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Root Access Required"),
        content: const Text(
          "This feature requires Root access to write directly to USB drives.\n\n"
          "Please root your device or grant permisions to use this tool.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), // Close screen
            child: const Text("Exit Tool"),
          ),
        ],
      ),
    ).then((_) => Navigator.pop(context));
  }

  Future<void> _pickIso() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType
          .any, // .iso not strictly supported filters in all file pickers properly sometimes
      // allowedExtensions: ['iso', 'img'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final file = File(path);
      final size = await file.length();

      setState(() {
        _isoPath = path;
        _isoSize = size;
      });
    }
  }

  Future<void> _startFlashing() async {
    if (_isoPath == null || _selectedDevice == null) return;

    // Safety Warning
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("WARNING: DATA LOSS"),
        content: Text(
          "Are you SURE you want to write to ${_selectedDevice!.name}?\n\n"
          "ALL DATA on ${_selectedDevice!.path} (${_selectedDevice!.sizeHumanReadable}) will be PERMANENTLY ERASED.\n\n"
          "This operation cannot be undone.",
          style: const TextStyle(color: Colors.red),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("ERASE & FLASH"),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isFlashing = true;
      _progress = 0.0;
      _progressStatus = "Starting...";
    });

    try {
      _flashProcess = await _usbService.flashIsoToDevice(
        _isoPath!,
        _selectedDevice!.path,
      );

      // Listen to stderr for progress (dd writes stats to stderr)
      _flashProcess!.stderr.transform(utf8.decoder).listen((data) {
        _parseDdProgress(data);
      });

      final exitCode = await _flashProcess!.exitCode;

      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progress = exitCode == 0 ? 1.0 : 0.0;
          _progressStatus = exitCode == 0
              ? "Success!"
              : "Failed (Code: $exitCode)";
        });

        if (exitCode == 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Flashing Complete! Safe to remove USB."),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Flashing Failed. Code: $exitCode")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progressStatus = "Error: $e";
        });
      }
    }
  }

  void _parseDdProgress(String data) {
    // Example: 209715200 bytes (210 MB, 200 MiB) copied, 5.003 s, 41.9 MB/s
    // Regex to capture bytes
    final regex = RegExp(r'(\d+) bytes');
    final match = regex.firstMatch(data);
    if (match != null && _isoSize != null && _isoSize! > 0) {
      final bytesCopied = int.parse(match.group(1)!);
      final pct = bytesCopied / _isoSize!;
      if (mounted) {
        setState(() {
          _progress = pct.clamp(0.0, 1.0);
          _progressStatus = "${filesize(bytesCopied)} / ${filesize(_isoSize!)}";
        });
      }
    }
  }

  @override
  void dispose() {
    _flashProcess?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Bootable USB Creator")),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Step 1: ISO Selection
                  _buildSectionHeader("1. Select ISO Image"),
                  Card(
                    child: ListTile(
                      title: Text(
                        _isoPath != null
                            ? _isoPath!.split('/').last
                            : "No ISO Selected",
                      ),
                      subtitle: _isoPath != null
                          ? Text(filesize(_isoSize))
                          : const Text("Tap to select .iso file"),
                      trailing: const Icon(Icons.folder_open),
                      onTap: _isFlashing ? null : _pickIso,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Step 2: Drive Selection
                  _buildSectionHeader("2. Select Target USB Drive"),
                  if (_devices.isEmpty)
                    const Card(
                      color: Colors.orangeAccent,
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          "No External Drives Detected.\nPlease plug in a USB OTG drive.",
                        ),
                      ),
                    )
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<BlockDevice>(
                            value: _selectedDevice,
                            isExpanded: true,
                            hint: const Text("Select Drive"),
                            onChanged: _isFlashing
                                ? null
                                : (val) =>
                                      setState(() => _selectedDevice = val),
                            items: _devices.map((device) {
                              return DropdownMenuItem(
                                value: device,
                                child: Text(
                                  "${device.name} (${device.sizeHumanReadable}) - ${device.path}",
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),

                  // Step 3: Flash
                  _buildSectionHeader("3. Flash Image"),
                  if (_isFlashing) ...[
                    LinearPercentIndicator(
                      lineHeight: 20.0,
                      percent: _progress,
                      center: Text("${(_progress * 100).toStringAsFixed(1)}%"),
                      progressColor: Colors.blue,
                    ),
                    const SizedBox(height: 10),
                    Text(_progressStatus, textAlign: TextAlign.center),
                  ] else ...[
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.flash_on),
                      label: const Text("START FLASHING"),
                      onPressed: (_isoPath != null && _selectedDevice != null)
                          ? _startFlashing
                          : null,
                    ),
                  ],

                  const SizedBox(height: 20),
                  const Text(
                    "Note: This tool uses the 'dd' command via Root access.\n"
                    "Ensure you select the correct drive to avoid data loss.",
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    );
  }
}
