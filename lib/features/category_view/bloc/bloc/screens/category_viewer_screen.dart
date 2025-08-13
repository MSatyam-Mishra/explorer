
import 'dart:typed_data';

import 'package:explorer/features/category_view/bloc/bloc/category_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';

class CategoryViewerScreen extends StatelessWidget {
  final RequestType  categoryType;
  final String title;

  const CategoryViewerScreen({
    super.key,
    required this.categoryType,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => CategoryBloc()..add(LoadCategoryAssets(categoryType)),
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
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
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          DateFormat.yMMMMd().format(date),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: assets.length,
                        itemBuilder: (context, assetIndex) {
                          final asset = assets[assetIndex];
                          return AssetBytesThumbnail(asset: assets[assetIndex]);
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

// Helper widget for displaying thumbnails efficiently
class AssetBytesThumbnail extends StatelessWidget {
  final AssetEntity asset;
  const AssetBytesThumbnail({super.key, required this.asset});

  @override
  Widget build(BuildContext context) {
    // We use a FutureBuilder to asynchronously get the thumbnail data
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailData,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Show a small loader while the thumbnail is loading
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        // If we have data, display it with Image.memory
        if (snapshot.hasData && snapshot.data != null) {
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
          );
        }
        // If there's an error or no data, show an error icon
        return const Icon(Icons.error_outline, color: Colors.redAccent);
      },
    );
  }
}