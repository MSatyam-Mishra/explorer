/// Plain data types shared by the 3D viewer screen, controller and panels.
library;

/// Lifecycle of the 3D viewer page.
enum ViewerPhase { preparing, loading, ready, error }

/// Canvas background behind the model.
enum ViewerBackground {
  dark('dark', 'Dark'),
  light('light', 'Light'),
  gradient('gradient', 'Gradient'),
  transparent('transparent', 'App');

  const ViewerBackground(this.id, this.label);

  final String id;
  final String label;

  static ViewerBackground fromId(Object? id) => ViewerBackground.values
      .firstWhere((b) => b.id == id, orElse: () => ViewerBackground.dark);
}

/// How meshes are shaded.
enum ViewerShading {
  original('original', 'Original'),
  flat('flat', 'Flat'),
  normals('normals', 'Normals');

  const ViewerShading(this.id, this.label);

  final String id;
  final String label;

  static ViewerShading fromId(Object? id) => ViewerShading.values
      .firstWhere((s) => s.id == id, orElse: () => ViewerShading.original);
}

/// Geometry statistics reported by the web viewer after loading.
class ModelStats {
  const ModelStats({
    required this.format,
    required this.meshes,
    required this.vertices,
    required this.triangles,
    required this.points,
    required this.lines,
    required this.skinnedMeshes,
    required this.materials,
    required this.textures,
    required this.animations,
    required this.sizeX,
    required this.sizeY,
    required this.sizeZ,
  });

  factory ModelStats.fromJson(Map<String, dynamic> json) {
    final size = json['size'] is Map
        ? Map<String, dynamic>.from(json['size'] as Map)
        : const <String, dynamic>{};
    return ModelStats(
      format: json['format']?.toString() ?? '',
      meshes: _int(json['meshes']),
      vertices: _int(json['vertices']),
      triangles: _int(json['triangles']),
      points: _int(json['points']),
      lines: _int(json['lines']),
      skinnedMeshes: _int(json['skinnedMeshes']),
      materials: _int(json['materials']),
      textures: _int(json['textures']),
      animations: _int(json['animations']),
      sizeX: _double(size['x']),
      sizeY: _double(size['y']),
      sizeZ: _double(size['z']),
    );
  }

  final String format;
  final int meshes;
  final int vertices;
  final int triangles;
  final int points;
  final int lines;
  final int skinnedMeshes;
  final int materials;
  final int textures;
  final int animations;
  final double sizeX;
  final double sizeY;
  final double sizeZ;
}

/// One animation clip contained in the model.
class AnimationClipInfo {
  const AnimationClipInfo({
    required this.index,
    required this.name,
    required this.duration,
  });

  factory AnimationClipInfo.fromJson(Map<String, dynamic> json) =>
      AnimationClipInfo(
        index: _int(json['index']),
        name: json['name']?.toString() ?? 'Animation',
        duration: _double(json['duration']),
      );

  final int index;
  final String name;

  /// Length in seconds.
  final double duration;
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

double _double(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
