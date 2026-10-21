part of 'sidebar_bloc.dart';

@immutable
abstract class SidebarState {}

class SidebarLoading extends SidebarState {}

class SidebarLoaded extends SidebarState {
  final List<Category> categories;
  final List<Directory> externalStorage;
  SidebarLoaded(this.categories, {this.externalStorage = const []});
}
