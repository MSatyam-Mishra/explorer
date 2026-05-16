import 'dart:io';
import 'dart:typed_data';
import 'package:explorer/features/category_view/bloc/bloc/category_bloc.dart';

import 'package:explorer/features/file_explorere/widgets/file_type_icon.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

class CategoryViewerScreen extends StatelessWidget {
  final RequestType categoryType;
  final String title;
  final String? path;

  const CategoryViewerScreen({
    super.key,
    required this.categoryType,
    required this.title,
    this.path,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => CategoryBloc()..add(LoadCategoryAssets(categoryType, path: path)),
      child: ExplorerScaffold(
        title: title,
        body: BlocBuilder<CategoryBloc, CategoryState>(
          builder: (context, state) {
            if (state is CategoryLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is CategoryError) {
              return Center(child: Text(state.message));
            }
            if (state is CategoryLoaded) {
              final dates = state.groupedAssets.keys.toList();
              return ListView.builder(
                itemCount: dates.length,
                itemBuilder: (context, index) {
                  final date = dates[index];
                  final assets = state.groupedAssets[date]!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                        child: Text(
                          DateFormat.yMMMMd().format(date),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        itemCount: assets.length,
                        itemBuilder: (context, assetIndex) {
                          final item = assets[assetIndex];

                          // --- THIS IS THE FIX ---
                          if (item is AssetEntity) {
                            return AssetBytesThumbnail(asset: item);
                          } else if (item is FileSystemEntity) {
                            return FileTypeIcon(filePath: item.path);
                          }
                          return const SizedBox.shrink();
                          // -----------------------
                        },
                      ),
                    ],
                  );
                },
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

// This helper widget for media thumbnails is still correct
class AssetBytesThumbnail extends StatelessWidget {
  final AssetEntity asset;
  const AssetBytesThumbnail({super.key, required this.asset});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailData,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasData && snapshot.data != null) {
          return Image.memory(snapshot.data!, fit: BoxFit.cover);
        }
        return const Icon(Icons.error_outline, color: Colors.redAccent);
      },
    );
  }
}