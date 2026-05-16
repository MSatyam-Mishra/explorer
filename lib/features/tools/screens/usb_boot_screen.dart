import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:filesize/filesize.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import 'package:explorer/core/services/root_service.dart';
import 'package:explorer/core/services/usb_host_service.dart';
import 'package:explorer/core/services/usb_boot_service.dart';

class UsbBootScreen extends StatefulWidget {
  const UsbBootScreen({super.key});

  @override
  State<UsbBootScreen> createState() => _UsbBootScreenState();
}

class _UsbBootScreenState extends State<UsbBootScreen> {
  final _rootService = RootService();
  final _usbRootService = UsbBootService();
  final _usbHostService = UsbHostService();

  bool _isLoading = true;
  bool _useRoot = false; // Default to Rootless if possible
  String? _isoPath;
  int? _isoSize;

  // Union type for selection (Root BlockDevice or Rootless UsbDeviceWrapper)
  dynamic _selectedDevice;
  List<dynamic> _devices = [];

  bool _isFlashing = false;
  double _progress = 0.0;
  String _progressStatus = '';
  Process? _flashProcess;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _usbHostService.init();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    _devices = [];
    _selectedDevice = null;

    try {
      if (_useRoot) {
        // Root Logic
        bool rooted = await _rootService.isRooted();
        if (!rooted) rooted = await _rootService.requestRootAccess();

        if (rooted) {
          final devices = await _usbRootService.getConnectableDevices();
          if (mounted) {
            setState(() {
              _devices = devices;
              if (devices.isNotEmpty) _selectedDevice = devices.first;
            });
          }
        }
      } else {
        // Rootless Logic
        final devices = await _usbHostService.getDeviceList();
        if (mounted) {
          setState(() {
            _devices = devices;
            if (devices.isNotEmpty) _selectedDevice = devices.first;
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading devices: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickIso() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
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

    // Safety check
    final deviceName = _useRoot
        ? (_selectedDevice as BlockDevice).name
        : (_selectedDevice as UsbDeviceWrapper).name;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("WARNING: DATA LOSS"),
        content: Text(
          "Are you SURE you want to write to $deviceName?\n\nALL DATA will be ERASED.",
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
      if (_useRoot) {
        // Root Flash (dd)
        _flashProcess = await _usbRootService.flashIsoToDevice(
          _isoPath!,
          (_selectedDevice as BlockDevice).path,
        );
        _flashProcess!.stderr.transform(utf8.decoder).listen((data) {
          // Parse dd progress (same as before)
          final regex = RegExp(r'(\d+) bytes');
          final match = regex.firstMatch(data);
          if (match != null && _isoSize != null) {
            final bytes = int.parse(match.group(1)!);
            if (mounted)
              setState(() {
                _progress = (bytes / _isoSize!).clamp(0.0, 1.0);
                _progressStatus = "${filesize(bytes)} / ${filesize(_isoSize)}";
              });
          }
        });
        await _flashProcess!.exitCode;
      } else {
        // Rootless Flash
        final wrapper = _selectedDevice as UsbDeviceWrapper;

        // Request Permission
        bool hasPerm = await _usbHostService.hasPermission(wrapper);
        if (!hasPerm) {
          hasPerm = await _usbHostService.requestPermission(wrapper);
        }

        if (!hasPerm) {
          throw Exception("USB Permission Denied");
        }

        await _usbHostService.flashIsoToDevice(
          File(_isoPath!),
          wrapper,
          onProgress: (pct) {
            if (mounted)
              setState(() {
                _progress = pct;
                _progressStatus = "${(pct * 100).toStringAsFixed(1)}%";
              });
          },
        );
      }

      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progress = 1.0;
          _progressStatus = "Success!";
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Flashing Complete!")));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progressStatus = "Error: $e";
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  @override
  void dispose() {
    _flashProcess?.kill();
    _usbHostService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Bootable USB Creator',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Root Mode',
            style: TextStyle(color: ClearGlassForeground.primaryText(context)),
          ),
          Switch(
            value: _useRoot,
            onChanged: _isFlashing
                ? null
                : (v) {
                    setState(() => _useRoot = v);
                    _loadDevices();
                  },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_useRoot)
              const Card(
                color: Colors.blueAccent,
                child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text(
                    "Rootless Mode: Uses Android USB Host API. Requires OTG adapter.",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            // Step 1: ISO
            _buildSectionHeader("1. Select ISO Image"),
            Card(
              child: ListTile(
                title: Text(_isoPath?.split('/').last ?? "No ISO Selected"),
                subtitle: Text(
                  _isoPath != null ? filesize(_isoSize) : "Tap to select",
                ),
                trailing: const Icon(Icons.folder_open),
                onTap: _isFlashing ? null : _pickIso,
              ),
            ),
            const SizedBox(height: 24),

            // Step 2: Device
            _buildSectionHeader("2. Select Target USB Drive"),
            if (_devices.isEmpty)
              const Card(
                color: Colors.orangeAccent,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text("No Drives Detected"),
                ),
              )
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<dynamic>(
                      value: _selectedDevice,
                      isExpanded: true,
                      onChanged: _isFlashing
                          ? null
                          : (v) => setState(() => _selectedDevice = v),
                      items: _devices.map((d) {
                        String label = _useRoot
                            ? "${(d as BlockDevice).name} (${d.sizeHumanReadable})"
                            : "${(d as UsbDeviceWrapper).name} (ID: ${d.productId})";
                        return DropdownMenuItem(value: d, child: Text(label));
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
                percent: _progress.clamp(0.0, 1.0),
                center: Text("${(_progress * 100).toStringAsFixed(1)}%"),
                progressColor: Colors.blue,
              ),
              Text(_progressStatus, textAlign: TextAlign.center),
            ] else
              ElevatedButton.icon(
                icon: const Icon(Icons.flash_on),
                label: const Text("START FLASHING"),
                onPressed: (_isoPath != null && _selectedDevice != null)
                    ? _startFlashing
                    : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, top: 16.0),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    );
  }
}
