import 'dart:io';

import 'package:explorer/core/services/localsend/localsend.dart';
import 'package:explorer/features/localsend/localsend_controller.dart';
import 'package:explorer/features/localsend/widgets/localsend_common.dart';
import 'package:explorer/features/localsend/widgets/localsend_dialogs.dart';
import 'package:explorer/features/localsend/widgets/localsend_receive_panel.dart';
import 'package:explorer/features/localsend/widgets/localsend_send_panel.dart';
import 'package:explorer/features/localsend/widgets/localsend_settings_sheet.dart';
import 'package:explorer/shared/widgets/clear_glass_panel.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

/// Nearby sharing over the LocalSend protocol: send [initialItems] (files and
/// folders) to, or receive files from, devices running LocalSend on the same
/// network. The receiver and discovery run only while this screen is open.
class LocalSendScreen extends StatefulWidget {
  const LocalSendScreen({super.key, this.initialItems = const []});

  final List<FileSystemEntity> initialItems;

  @override
  State<LocalSendScreen> createState() => _LocalSendScreenState();
}

class _LocalSendScreenState extends State<LocalSendScreen>
    with SingleTickerProviderStateMixin {
  late final LocalSendController _controller = LocalSendController(
    initialItems: widget.initialItems,
  );
  late final TabController _tabs;
  String? _shownReceiveSession;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialItems.isEmpty ? 1 : 0,
    );
    _controller
      ..incomingHandler = _askIncoming
      ..pinPrompt = _askPin
      ..addListener(_onControllerChanged);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// Jump to the receive tab when an incoming transfer starts (phones).
  void _onControllerChanged() {
    final session = _controller.receiveSession;
    if (session != null && session.id != _shownReceiveSession) {
      _shownReceiveSession = session.id;
      if (_tabs.index != 1) _tabs.animateTo(1);
    }
  }

  Future<LsReceiveDecision> _askIncoming(LsIncomingRequest request) async {
    if (!mounted) return const LsReceiveDecision.decline();
    final fingerprint = request.sender.fingerprint.toUpperCase();
    final answer = await showLsIncomingDialog(
      context,
      request,
      alreadyTrusted: _controller.trusted.containsKey(fingerprint),
    );
    if (answer.accept && answer.trust) await _controller.trust(request.sender);
    return answer.accept
        ? const LsReceiveDecision.accept()
        : const LsReceiveDecision.decline();
  }

  Future<String?> _askPin({required bool invalid}) async {
    if (!mounted) return null;
    final alias = _controller.sendSession?.target.alias ?? 'receiver';
    return showLsPinDialog(context, deviceAlias: alias, invalid: invalid);
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = ClearGlassForeground.icon(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => PopScope(
        canPop: !_transferRunning,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave() && context.mounted) {
            Navigator.of(context).pop();
          }
        },
        child: _scaffold(context, iconColor),
      ),
    );
  }

  bool get _transferRunning =>
      (_controller.sendSession != null && !_controller.sendSession!.isDone) ||
      (_controller.receiveSession?.isActive ?? false);

  Future<bool> _confirmLeave() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => lsThemed(
        context,
        AlertDialog(
          title: const Text('Stop the transfer?'),
          content: const Text(
            'Leaving this screen cancels the running transfer and stops nearby sharing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Stop and leave'),
            ),
          ],
        ),
      ),
    );
    return answer ?? false;
  }

  Widget _scaffold(BuildContext context, Color iconColor) => ExplorerScaffold(
    title: 'Nearby share',
    trailing: ExplorerTopBar.actions(context, [
      ExplorerTopBar.iconButton(
        context: context,
        icon: Icon(Icons.settings_outlined, color: iconColor),
        tooltip: 'Settings',
        onPressed: _controller.settings == null
            ? null
            : () => showLsSettingsSheet(context, _controller),
      ),
    ]),
    body: Theme(data: lsTheme(context), child: _body(context)),
  );

  Widget _body(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = 16 + MediaQuery.paddingOf(context).bottom;
    if (_controller.starting) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Starting nearby sharing…'),
            ],
          ),
        ),
      );
    }
    final error = _controller.startupError;
    if (error != null) {
      return Padding(
        padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
        child: Center(child: Text(error, textAlign: TextAlign.center)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 840) {
          // Tablet / desktop: send and receive side by side.
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LsSendPanel(
                  controller: _controller,
                  padding: EdgeInsets.fromLTRB(16, top + 4, 8, bottom),
                ),
              ),
              Expanded(
                child: LsReceivePanel(
                  controller: _controller,
                  padding: EdgeInsets.fromLTRB(8, top + 4, 16, bottom),
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: top),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(icon: Icon(Icons.upload), text: 'Send'),
                Tab(icon: Icon(Icons.download), text: 'Receive'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  LsSendPanel(
                    controller: _controller,
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottom),
                  ),
                  LsReceivePanel(
                    controller: _controller,
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottom),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
