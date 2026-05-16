import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

class VaultScreen extends StatelessWidget {
  const VaultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ExplorerScaffold(
      title: 'Secure Vault',
      body: Center(
        child: Text('Vault Unlocked! Content will go here.'),
      ),
    );
  }
}