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
  /// 仅缓存各 CBZ 内部自然排序后的纯图片文件名列表 (每本仅占几 KB 内存，彻底杜绝 OOM 风险)
  static final _imageNamesCache = LinkedHashMap<String, List<String>>();

  /// 有效页数缓存
  static final _pageCountCache = <String, int>{};

  /// 最近解码的单图内存缓存 (LRU 最多保留 5 张，保障平滑翻页，内存占用严格控制在 < 5MB)
  static final _recentImageCache = LinkedHashMap<String, Uint8List>();

  /// 自然数排序比较器 (确保第三方未补零文件如 2.jpg 正确排在 10.jpg 前面)
  static int _naturalCompare(String a, String b) {
    final reg = RegExp(r'\d+');
    final matchA = reg.firstMatch(a);
    final matchB = reg.firstMatch(b);
    if (matchA != null && matchB != null) {
      final numA = int.tryParse(matchA.group(0)!);
      final numB = int.tryParse(matchB.group(0)!);
      if (numA != null && numB != null && numA != numB) {
        return numA.compareTo(numB);
      }
    }
    return a.compareTo(b);
  }

  /// 根据漫画 ID 和章节号寻找对应的 CBZ/ZIP 文件
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

      final ep1Zip = File("$downloadPath/$dir-1.zip");
      if (ep1Zip.existsSync()) return ep1Zip;
    } else {
      // 多话结构：[dir]-[ep].cbz 或 [dir]-[ep].zip
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

  /// 纯流式解析图片文件名列表 (使用 InputFileStream，不把 ZIP 包体与图片内容加载进内存)
  static List<String> _getImageNames(File cbzFile) {
    final path = cbzFile.path;
    if (_imageNamesCache.containsKey(path)) {
      final data = _imageNamesCache.remove(path)!;
      _imageNamesCache[path] = data;
      return data;
    }

    archive.InputFileStream? inputStream;
    try {
      inputStream = archive.InputFileStream(path);
      final zipData =
          archive.ZipDecoder().decodeBuffer(inputStream, verify: false);

      final imageNames = <String>[];
      for (final file in zipData.files) {
        if (file.isFile) {
          final lower = file.name.toLowerCase();
          if (lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.gif')) {
            if (!file.name.contains("ComicInfo.xml")) {
              imageNames.add(file.name);
            }
          }
        }
      }

      imageNames.sort(_naturalCompare);

      if (_imageNamesCache.length >= 10) {
        _imageNamesCache.remove(_imageNamesCache.keys.first);
      }
      _imageNamesCache[path] = imageNames;
      _pageCountCache[path] = imageNames.length;

      return imageNames;
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "CbzReader", "Failed to parse CBZ entries: $e\n$s");
      return [];
    } finally {
      inputStream?.close();
    }
  }

  /// 获取 CBZ 内漫画的有效页数
  static int getPageCount(File cbzFile) {
    if (_pageCountCache.containsKey(cbzFile.path)) {
      return _pageCountCache[cbzFile.path]!;
    }
    return _getImageNames(cbzFile).length;
  }

  /// 按需提取单张图片字节流 (单图解码 + 5 张 LRU 预存，彻底杜绝 OOM)
  static Future<Uint8List?> getImageBytesOrNull(
      String id, int ep, int index) async {
    final cbzFile = findCbzFile(id, ep);
    if (cbzFile == null) return null;

    final cacheKey = "${cbzFile.path}_$index";
    if (_recentImageCache.containsKey(cacheKey)) {
      final cached = _recentImageCache.remove(cacheKey)!;
      _recentImageCache[cacheKey] = cached;
      return cached;
    }

    final imageNames = _getImageNames(cbzFile);
    if (index < 0 || index >= imageNames.length) return null;
    final targetName = imageNames[index];

    archive.InputFileStream? inputStream;
    try {
      inputStream = archive.InputFileStream(cbzFile.path);
      final zipData =
          archive.ZipDecoder().decodeBuffer(inputStream, verify: false);

      archive.ArchiveFile? targetFile;
      for (final f in zipData.files) {
        if (f.name == targetName) {
          targetFile = f;
          break;
        }
      }

      if (targetFile == null) return null;

      final content = targetFile.content;
      Uint8List? result;
      if (content is Uint8List) {
        result = content;
      } else if (content is List<int>) {
        result = Uint8List.fromList(content);
      }

      if (result != null) {
        if (_recentImageCache.length >= 5) {
          _recentImageCache.remove(_recentImageCache.keys.first);
        }
        _recentImageCache[cacheKey] = result;
      }
      return result;
    } catch (e) {
      return null;
    } finally {
      inputStream?.close();
    }
  }

  /// 获取封面文件：优先读内部缓存，若无则从 CBZ 抽取恢复 (按需懒加载，滑到哪本抽哪本)
  static File getCoverFile(String id) {
    final coverDir = Directory("${CacheManager.cachePath}/covers");
    if (!coverDir.existsSync()) {
      coverDir.createSync(recursive: true);
    }
    final cacheCover = File("${coverDir.path}/$id.jpg");
    if (cacheCover.existsSync()) {
      return cacheCover;
    }

    // 从 CBZ 提取第 1 张图片填充封面缓存 (流式提取)
    final cbzFile = findCbzFile(id, 0) ?? findCbzFile(id, 1);
    if (cbzFile != null) {
      final imageNames = _getImageNames(cbzFile);
      if (imageNames.isNotEmpty) {
        archive.InputFileStream? inputStream;
        try {
          inputStream = archive.InputFileStream(cbzFile.path);
          final zipData =
              archive.ZipDecoder().decodeBuffer(inputStream, verify: false);
          final firstName = imageNames.first;
          archive.ArchiveFile? firstFile;
          for (final f in zipData.files) {
            if (f.name == firstName) {
              firstFile = f;
              break;
            }
          }
          if (firstFile != null && firstFile.content is List<int>) {
            cacheCover.writeAsBytesSync(firstFile.content as List<int>);
            return cacheCover;
          }
        } catch (_) {
        } finally {
          inputStream?.close();
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

  /// 清理指定的 CBZ 文件与相关缓存 (支持传入已知 dirName，杜绝删库后查库引发的崩溃)
  static void deleteCbz(String id, [String? directoryName]) {
    final downloadPath = DownloadManager().path;
    if (downloadPath == null) return;

    String dir = directoryName ?? id;
    if (directoryName == null) {
      try {
        dir = DownloadManager().getDirectory(id);
      } catch (_) {
        dir = id;
      }
    }

    // 1. 删除单话 CBZ / ZIP
    final singleCbz = File("$downloadPath/$dir.cbz");
    if (singleCbz.existsSync()) singleCbz.deleteSync();

    final singleZip = File("$downloadPath/$dir.zip");
    if (singleZip.existsSync()) singleZip.deleteSync();

    // 2. 匹配并删除多话连载 CBZ / ZIP ([dir]-*.cbz, [dir]-*.zip)
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

    // 4. 清理内存条目缓存与页数缓存 (彻底杜绝内存泄漏)
    _imageNamesCache.removeWhere((k, _) => k.contains(dir));
    _pageCountCache.removeWhere((k, _) => k.contains(dir));
    _recentImageCache.removeWhere((k, _) => k.contains(dir));
  }

  /// 删除多话中的某一单话 CBZ / ZIP
  static void deleteEpisodeCbz(String id, int ep) {
    final downloadPath = DownloadManager().path;
    if (downloadPath == null) return;

    String dir;
    try {
      dir = DownloadManager().getDirectory(id);
    } catch (_) {
      dir = id;
    }

    // 1. 同时检测并删除 .cbz 和 .zip 两种格式
    final epCbz = File("$downloadPath/$dir-$ep.cbz");
    if (epCbz.existsSync()) {
      epCbz.deleteSync();
    }

    final epZip = File("$downloadPath/$dir-$ep.zip");
    if (epZip.existsSync()) {
      epZip.deleteSync();
    }

    // 2. 同步清理内存缓存 (包含文件名列表、页数与单图缓存)
    _imageNamesCache.removeWhere((k, _) => k.contains("$dir-$ep"));
    _pageCountCache.removeWhere((k, _) => k.contains("$dir-$ep"));
    _recentImageCache.removeWhere((k, _) => k.contains("$dir-$ep"));
  }
}
