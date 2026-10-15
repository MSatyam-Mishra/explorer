import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Bookmark {
  final String id;
  final dynamic position; // int for PDF page, int/String for EPUB CFI/Index
  final String label;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.position,
    required this.label,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'position': position,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'],
    position: json['position'],
    label: json['label'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}

class BookData {
  dynamic lastReadPosition;
  List<Bookmark> bookmarks;

  // Growable copy: a const default list would make the first add() throw.
  BookData({this.lastReadPosition, List<Bookmark>? bookmarks})
    : bookmarks = [...?bookmarks];

  Map<String, dynamic> toJson() => {
    'lastReadPosition': lastReadPosition,
    'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
  };

  factory BookData.fromJson(Map<String, dynamic> json) => BookData(
    lastReadPosition: json['lastReadPosition'],
    bookmarks:
        (json['bookmarks'] as List?)
            ?.map((b) => Bookmark.fromJson(b))
            .toList() ??
        [],
  );
}

class BookmarkService {
  static final BookmarkService _instance = BookmarkService._internal();
  factory BookmarkService() => _instance;
  BookmarkService._internal();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String _getKey(String filePath) {
    final hash = md5.convert(utf8.encode(filePath)).toString();
    return 'book_data_$hash';
  }

  Future<BookData> _getBookData(String filePath) async {
    await init();
    final key = _getKey(filePath);
    final jsonStr = _prefs?.getString(key);
    if (jsonStr == null) return BookData();
    return BookData.fromJson(jsonDecode(jsonStr));
  }

  Future<void> _saveBookData(String filePath, BookData data) async {
    await init();
    final key = _getKey(filePath);
    await _prefs?.setString(key, jsonEncode(data.toJson()));
  }

  Future<dynamic> getLastReadPosition(String filePath) async {
    final data = await _getBookData(filePath);
    return data.lastReadPosition;
  }

  Future<void> saveLastReadPosition(String filePath, dynamic position) async {
    final data = await _getBookData(filePath);
    data.lastReadPosition = position;
    await _saveBookData(filePath, data);
  }

  Future<List<Bookmark>> getBookmarks(String filePath) async {
    final data = await _getBookData(filePath);
    return data.bookmarks;
  }

  Future<void> addBookmark(
    String filePath,
    dynamic position,
    String label,
  ) async {
    final data = await _getBookData(filePath);
    final newBookmark = Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      position: position,
      label: label,
      createdAt: DateTime.now(),
    );
    data.bookmarks.add(newBookmark);
    await _saveBookData(filePath, data);
  }

  Future<void> removeBookmark(String filePath, String bookmarkId) async {
    final data = await _getBookData(filePath);
    data.bookmarks.removeWhere((b) => b.id == bookmarkId);
    await _saveBookData(filePath, data);
  }
}
