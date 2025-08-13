part of 'category_bloc.dart';

@immutable
abstract class CategoryEvent {}

class LoadCategoryAssets extends CategoryEvent {
  final RequestType type;
  final String? path; // Add this to pass the directory path
  LoadCategoryAssets(this.type, {this.path});
}