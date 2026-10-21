import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

class VaultScreen extends StatelessWidget {
  const VaultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    return ExplorerScaffold(
      title: 'Vault',
      body: ExplorerEmptyState(
        padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
        icon: LucideIcons.lockKeyhole,
        title: 'Your vault is empty',
        description: 'Files in the vault stay hidden from other apps and only '
            'open after you unlock Explorer. Moving files into the vault is '
            'coming soon.',
      ),
    );
  }
}
