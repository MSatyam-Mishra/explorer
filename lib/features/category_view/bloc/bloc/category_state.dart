part of 'category_bloc.dart';

@immutable
abstract class CategoryState {}

class CategoryLoading extends CategoryState {}

class CategoryLoaded extends CategoryState {
  // Change this to handle both AssetEntity and FileSystemEntity
  final Map<DateTime, List<dynamic>> groupedAssets;
  CategoryLoaded(this.groupedAssets);
}

class CategoryError extends CategoryState {
  final String message;
  CategoryError(this.message);
}