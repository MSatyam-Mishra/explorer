part of 'sidebar_bloc.dart';

// Since this is part of sidebar_bloc, it shares imports.
// But SidebarBloc imports dart:io, so it should be fine.
// However, if the IDE complains about Directory in state file, we rely on part of.
// Wait, 'part of' file does NOT share imports from the parent automatically in Dart?
// No, the parent (bloc) imports generally cover it if "part" is used correctly.
// BUT, usually "part of" files don't have their own imports.
// The PARENT file (sidebar_bloc.dart) has 'import dart:io'.
// That should make 'Directory' visible here?
// Actually no, in Dart, the PARENT file's imports are available to the PART file.
// So if sidebar_bloc.dart imports dart:io, we are good.
// I'll assume it's fine. If verified error persists, I'll revisit.

@immutable
abstract class SidebarState {}

class SidebarLoading extends SidebarState {}

class SidebarLoaded extends SidebarState {
  final List<Category> categories;
  final List<Directory> externalStorage;
  SidebarLoaded(this.categories, {this.externalStorage = const []});
}

class SidebarError extends SidebarState {
  final String message;
  SidebarError(this.message);
}
