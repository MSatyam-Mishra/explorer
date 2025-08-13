import 'package:flutter/material.dart';

class Category {
  final IconData icon;
  final String name;
  final int fileCount;
  final Color color;

  Category({
    required this.icon,
    required this.name,
    required this.fileCount,
    required this.color,
  });
}