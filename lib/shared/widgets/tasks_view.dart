import 'dart:io';

import 'package:explorer/core/build_features.dart';
import 'package:explorer/core/platform/background_mode.dart';
import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/services/background_tasks.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_controller.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Only the tasks: what's left of the app while work goes on after its
/// window was closed (see [BackgroundMode]).
class TasksView extends StatelessWidget {
  const TasksView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final downloads = kVideoDownloaderEnabled && VideoDownloaderController.instance.isStarted
        ? VideoDownloaderController.instance
        : null;
    return Material(
      color: colors.background,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([BackgroundTasks.instance, ?downloads]),
          builder: (context, _) {
            final tasks = BackgroundTasks.instance.all;
            final jobs = downloads?.jobs.where((j) => j.isActive).toList() ?? const [];
            final running = tasks.where((t) => t.isRunning).length + jobs.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Row(
                    children: [
                      Icon(LucideIcons.listChecks, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Explorer tasks', style: text.titleMedium),
                            Text(
                              running == 0
                                  ? 'All done'
                                  : running == 1
                                      ? '1 running'
                                      : '$running running',
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (tasks.any((t) => !t.isRunning))
                        TextButton(
                          onPressed: BackgroundTasks.instance.clearFinished,
                          child: const Text('Clear finished'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: tasks.isEmpty && jobs.isEmpty
                      ? Center(child: Text('Nothing is running.', style: text.bodyMedium))
                      : ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (final job in jobs)
                              _TaskCard(
                                status: TaskStatus.running,
                                title: job.title ?? job.url,
                                message: job.percent == null ? 'Downloading' : '${job.percent!.round()}%',
                                progress: job.percent == null ? null : job.percent! / 100,
                                onCancel: () => downloads!.cancel(job.id),
                              ),
                            for (final task in tasks)
                              _TaskCard(
                                status: task.status,
                                title: task.title,
                                message: task.message,
                                progress: task.progress,
                                onCancel: task.canCancel ? task.cancel : null,
                                onShow: !task.isRunning && task.outputs.isNotEmpty && Desktop.isDesktop
                                    ? () => Desktop.openWindow(folder: p.dirname(task.outputs.first))
                                    : null,
                              ),
                          ],
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: BackgroundMode.instance.close,
                          child: Text(running == 0 ? 'Quit' : (Platform.isWindows ? 'Hide' : 'Close')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: BackgroundMode.instance.openExplorer,
                          child: const Text('Open Explorer'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.status,
    required this.title,
    required this.message,
    required this.progress,
    this.onCancel,
    this.onShow,
  });

  final TaskStatus status;
  final String title;
  final String message;
  final double? progress;
  final VoidCallback? onCancel;
  final VoidCallback? onShow;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final icon = switch (status) {
      TaskStatus.running => SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
        ),
      TaskStatus.done => Icon(LucideIcons.circleCheck, size: 18, color: colors.primary),
      TaskStatus.failed => Icon(LucideIcons.circleAlert, size: 18, color: colors.destructive),
      TaskStatus.cancelled => Icon(LucideIcons.circleSlash, size: 18, color: colors.mutedForeground),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppPanel(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                ),
                if (onShow != null) TextButton(onPressed: onShow, child: const Text('Show in folder')),
                if (onCancel != null) TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 6, top: 2),
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: status == TaskStatus.failed ? colors.destructive : null),
              ),
            ),
            if (status == TaskStatus.running)
              Padding(
                padding: const EdgeInsets.only(left: 28, right: 6, top: 8),
                child: LinearProgressIndicator(value: progress, minHeight: 5),
              ),
          ],
        ),
      ),
    );
  }
}
