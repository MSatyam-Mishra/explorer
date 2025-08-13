part of 'sidebar_bloc.dart';

@immutable
abstract class SidebarState {}

class SidebarLoading extends SidebarState {}

class SidebarLoaded extends SidebarState {
  final List<Category> categories;
  SidebarLoaded(this.categories);
}

class SidebarError extends SidebarState {
  final String message;
  SidebarError(this.message);
}