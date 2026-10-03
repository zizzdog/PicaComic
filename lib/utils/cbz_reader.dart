import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart' as archive;
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/utils/io_extensions.dart';

class CbzReader {
  /// 缓存已解析的 CBZ 归档文件条目 (LRU 缓存最近 3 本，避免每次翻页重复读盘解析)
  static final _archiveCache = LinkedHashMap<String, List<archive.ArchiveFile>>();
  static final _pageCountCache = <String, int>{};

  /// 根据漫画 ID 和章节号寻找对应的 CBZ 文件
  static File? findCbzFile(String id, int ep) {
    final downloadPath = DownloadManager().path;
    if (downloadPath == null) return null;

    String dir;
    try {
      dir = DownloadManager().getDirectory(id);
    } catch (_) {
      dir = id;
    }

    if (ep <= 1) {
      // 优先找单话平铺的 [dir].cbz
      final singleCbz = File("$downloadPath/$dir.cbz");
      if (singleCbz.existsSync()) return singleCbz;

      // 其次找带章节编号的 [dir]-1.cbz
      final ep1Cbz = File("$downloadPath/$dir-1.cbz");
      if (ep1Cbz.existsSync()) return ep1Cbz;

      // 兼容 .zip
      final singleZip = File("$downloadPath/$dir.zip");
      if (singleZip.existsSync()) return singleZip;
    } else {
      // 多话结构：[dir]-[ep].cbz
      final epCbz = File("$downloadPath/$dir-$ep.cbz");
      if (epCbz.existsSync()) return epCbz;

      final epZip = File("$downloadPath/$dir-$ep.zip");
      if (epZip.existsSync()) return epZip;
    }

    return null;
  }

  /// 检查某本漫画是否以 CBZ 形式存储
  static bool isCbzComic(String id) {
    return findCbzFile(id, 0) != null || findCbzFile(id, 1) != null;
  }

  /// 获取 CBZ 内包含的漫画图片列表 (排除 ComicInfo.xml 与文件夹，并自然排序)
  static List<archive.ArchiveFile> _getImageEntries(File cbzFile) {
    final path = cbzFile.path;
    if (_archiveCache.containsKey(path)) {
      // 提升至最近使用
      final data = _archiveCache.remove(path)!;
      _archiveCache[path] = data;
      return data;
    }

    try {
      final bytes = cbzFile.readAsBytesSync();
      final zipData = archive.ZipDecoder().decodeBytes(bytes, verify: false);

      final imageFiles = <archive.ArchiveFile>[];
      for (final file in zipData) {
        if (file.isFile) {
          final lower = file.name.toLowerCase();
          if (lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.gif')) {
            if (!file.name.contains("ComicInfo.xml")) {
              imageFiles.add(file);
            }
          }
        }
      }

      imageFiles.sort((a, b) => a.name.compareTo(b.name));

      if (_archiveCache.length >= 3) {
        _archiveCache.remove(_archiveCache.keys.first);
      }
      _archiveCache[path] = imageFiles;
      _pageCountCache[path] = imageFiles.length;

      return imageFiles;
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "CbzReader", "Failed to parse CBZ entries: $e\n$s");
      return [];
    }
  }

  /// 获取 CBZ 内漫画的有效页数
  static int getPageCount(File cbzFile) {
    if (_pageCountCache.containsKey(cbzFile.path)) {
      return _pageCountCache[cbzFile.path]!;
    }
    return _getImageEntries(cbzFile).length;
  }

  /// 内存流式提取单张图片字节流 (零磁盘临时文件，极致性能)
  static Future<Uint8List?> getImageBytesOrNull(
      String id, int ep, int index) async {
    final cbzFile = findCbzFile(id, ep);
    if (cbzFile == null) return null;

    final entries = _getImageEntries(cbzFile);
    if (index < 0 || index >= entries.length) return null;

    final file = entries[index];
    final content = file.content;
    if (content is Uint8List) {
      return content;
    } else if (content is List<int>) {
      return Uint8List.fromList(content);
    }
    return null;
  }

  /// 获取封面文件：优先读内部缓存，若无则从 CBZ 抽取恢复（按需懒加载，滑到哪本抽哪本）
  static File getCoverFile(String id) {
    final coverDir = Directory("${CacheManager.cachePath}/covers");
    if (!coverDir.existsSync()) {
      coverDir.createSync(recursive: true);
    }
    final cacheCover = File("${coverDir.path}/$id.jpg");
    if (cacheCover.existsSync()) {
      return cacheCover;
    }

    // 从 CBZ 提取第 1 张图片填充封面缓存
    final cbzFile = findCbzFile(id, 0) ?? findCbzFile(id, 1);
    if (cbzFile != null) {
      final entries = _getImageEntries(cbzFile);
      if (entries.isNotEmpty) {
        final firstImage = entries.first;
        final content = firstImage.content;
        if (content is List<int>) {
          cacheCover.writeAsBytesSync(content);
          return cacheCover;
        }
      }
    }

    // 兜底返回原生路径
    final downloadPath = DownloadManager().path ?? "";
    String dir;
    try {
      dir = DownloadManager().getDirectory(id);
    } catch (_) {
      dir = id;
    }
    return File("$downloadPath/$dir/cover.jpg");
  }

  /// 清理指定的 CBZ 文件与封面缓存
  static void deleteCbz(String id) {
    final downloadPath = DownloadManager().path;
    if (downloadPath == null) return;

    String dir;
    try {
      dir = DownloadManager().getDirectory(id);
    } catch (_) {
      dir = id;
    }

    // 1. 删除单话 CBZ
    final singleCbz = File("$downloadPath/$dir.cbz");
    if (singleCbz.existsSync()) singleCbz.deleteSync();

    final singleZip = File("$downloadPath/$dir.zip");
    if (singleZip.existsSync()) singleZip.deleteSync();

    // 2. 匹配并删除多话连载 CBZ ([dir]-*.cbz)
    final rootDir = Directory(downloadPath);
    if (rootDir.existsSync()) {
      for (final entity in rootDir.listSync()) {
        if (entity is File) {
          final filename = entity.name;
          if (filename.startsWith("$dir-") &&
              (filename.endsWith(".cbz") || filename.endsWith(".zip"))) {
            entity.deleteSync();
          }
        }
      }
    }

    // 3. 删除封面缓存
    final cacheCover = File("${CacheManager.cachePath}/covers/$id.jpg");
    if (cacheCover.existsSync()) {
      cacheCover.deleteSync();
    }

    // 清理内存条目缓存
    _archiveCache.removeWhere((k, _) => k.contains(dir));
  }

  /// 删除多话中的某一单话 CBZ
  static void deleteEpisodeCbz(String id, int ep) {
    final downloadPath = DownloadManager().path;
    if (downloadPath == null) return;

    String dir;
    try {
      dir = DownloadManager().getDirectory(id);
    } catch (_) {
      dir = id;
    }

    final epCbz = File("$downloadPath/$dir-$ep.cbz");
    if (epCbz.existsSync()) {
      epCbz.deleteSync();
      _archiveCache.remove(epCbz.path);
    }
  }
}
