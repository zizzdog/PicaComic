import 'dart:io';
import 'package:archive/archive_io.dart' as archive;
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/htmanga_network/htmanga_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/utils/cbz_config.dart';
import 'package:pica_comic/utils/io_extensions.dart';
import 'package:pica_comic/utils/io_tools.dart';
import 'package:pica_comic/utils/tags_translation.dart';
import 'package:xml/xml.dart';

class CbzBuilder {
  /// 当漫画下载完成后调用，自动打包为根目录的 .cbz 并抽取封面缓存
  static Future<void> packageDownloadedComic(
      DownloadedItem item, String directoryName) async {
    if (!CbzConfig.autoCbz) return;

    try {
      final downloadPath = DownloadManager().path;
      if (downloadPath == null) return;

      final sourceDir = Directory("$downloadPath/$directoryName");
      if (!sourceDir.existsSync()) return;

      // 1. 扫描判断单话与多话目录结构（封面采用纯按需懒加载，浏览刷到时才现场从 CBZ 抽取并纳入 CacheManager 管理）
      final entries = sourceDir.listSync();
      final epDirs = <Directory>[];

      for (var entry in entries) {
        if (entry is Directory) {
          final epNum = int.tryParse(entry.name);
          if (epNum != null) {
            epDirs.add(entry);
          }
        }
      }

      epDirs.sort((a, b) => int.parse(a.name).compareTo(int.parse(b.name)));

      final baseName = sanitizeFileName(item.name);

      // 3. 打包逻辑
      if (epDirs.isEmpty) {
        // 单话平铺结构 (EH/Hitomi/NHentai 等，图片直接散落在 sourceDir 根部)
        final targetCbz = File("$downloadPath/$baseName.cbz");
        final images = _getSortedImages(sourceDir);
        await _createCbz(
          targetCbz: targetCbz,
          images: images,
          item: item,
          epNumber: 1,
        );
      } else if (epDirs.length == 1) {
        // 单话嵌套结构 (如 JM/Picacg 单行本，只有 1/ 文件夹) -> 平铺至根目录的 [baseName].cbz
        final targetCbz = File("$downloadPath/$baseName.cbz");
        final images = _getSortedImages(epDirs.first);
        await _createCbz(
          targetCbz: targetCbz,
          images: images,
          item: item,
          epNumber: 1,
        );
      } else {
        // 多话连载结构 -> 分别生成 [baseName]-1.cbz, [baseName]-2.cbz
        for (var epDir in epDirs) {
          final epNum = int.parse(epDir.name);
          final targetCbz = File("$downloadPath/$baseName-$epNum.cbz");
          final images = _getSortedImages(epDir);
          await _createCbz(
            targetCbz: targetCbz,
            images: images,
            item: item,
            epNumber: epNum,
          );
        }
      }

      // 4. 清理原始散装小文件
      if (CbzConfig.deleteRaw) {
        sourceDir.deleteSync(recursive: true);
      }
    } catch (e, s) {
      LogManager.addLog(
          LogLevel.error, "CbzBuilder", "Failed to package CBZ: $e\n$s");
    }
  }

  /// 缓存封面至 App 内部空间（复用官方 CacheManager 路径以遵循缓存限制）
  static void _cacheCover(DownloadedItem item, Directory sourceDir) {
    try {
      final coverDir = Directory("${CacheManager.cachePath}/covers");
      if (!coverDir.existsSync()) {
        coverDir.createSync(recursive: true);
      }
      final cacheCoverFile = File("${coverDir.path}/${item.id}.jpg");

      // 优先从临时下载目录提取 cover.jpg
      final rawCover = File("${sourceDir.path}/cover.jpg");
      if (rawCover.existsSync()) {
        rawCover.copySync(cacheCoverFile.path);
        return;
      }

      // 若无 cover.jpg，尝试提取第一张图片作为封面
      final images = _getSortedImages(sourceDir);
      if (images.isNotEmpty) {
        images.first.copySync(cacheCoverFile.path);
        return;
      }

      // 检查子文件夹 1/ 内的第一张图片
      final ep1 = Directory("${sourceDir.path}/1");
      if (ep1.existsSync()) {
        final epImages = _getSortedImages(ep1);
        if (epImages.isNotEmpty) {
          epImages.first.copySync(cacheCoverFile.path);
        }
      }
    } catch (e) {
      LogManager.addLog(LogLevel.warning, "CbzBuilder", "Cache cover error: $e");
    }
  }

  /// 扫描并按序号自然排序图片
  static List<File> _getSortedImages(Directory dir) {
    final files = <File>[];
    for (var file in dir.listSync()) {
      if (file is File) {
        final lower = file.path.toLowerCase();
        if (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.gif')) {
          if (!file.name.startsWith("cover.")) {
            files.add(file);
          }
        }
      }
    }

    files.sort((a, b) {
      final numA = int.tryParse(a.name.replaceAll(RegExp(r'\..+$'), ''));
      final numB = int.tryParse(b.name.replaceAll(RegExp(r'\..+$'), ''));
      if (numA != null && numB != null) {
        return numA.compareTo(numB);
      }
      return a.name.compareTo(b.name);
    });

    return files;
  }

  /// 创建单个 CBZ 压缩文件（Store 无损极速打包）
  static Future<void> _createCbz({
    required File targetCbz,
    required List<File> images,
    required DownloadedItem item,
    required int epNumber,
  }) async {
    if (targetCbz.existsSync()) {
      targetCbz.deleteSync();
    }

    final encoder = archive.ZipFileEncoder();
    // level: 0 表示 Store 模式（仅存储，不压缩），极速写入
    encoder.create(targetCbz.path, level: 0);

    // 1. 生成并写入 ComicInfo.xml
    if (CbzConfig.embedComicInfo) {
      final xmlString = _buildComicInfoXml(item, epNumber, images.length);
      final tempXml = File("${App.cachePath}/temp_ComicInfo.xml");
      tempXml.writeAsStringSync(xmlString);
      encoder.addFile(tempXml, "ComicInfo.xml");
      try {
        tempXml.deleteSync();
      } catch (_) {}
    }

    // 2. 依次压入图片（统一规范文件名 0001.jpg 避免阅读器乱序）
    for (int i = 0; i < images.length; i++) {
      final ext = images[i].path.split('.').last;
      final formattedName = "${(i + 1).toString().padLeft(4, '0')}.$ext";
      encoder.addFile(images[i], formattedName);
    }

    encoder.close();
  }

  /// 基于 JHenTai 规范构建完整的 ComicInfo.xml
  static String _buildComicInfoXml(
      DownloadedItem item, int epNumber, int pageCount) {
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="utf-8"');

    builder.element('ComicInfo', nest: () {
      builder.attribute(
          'xmlns:xsi', 'http://www.w3.org/2001/XMLSchema-instance');
      builder.attribute(
          'xmlns:xsd', 'http://www.w3.org/2001/XMLSchema');

      builder.element('Title', nest: item.name);
      builder.element('Series', nest: item.name);
      builder.element('Number', nest: epNumber.toString());

      if (item.subTitle.isNotEmpty) {
        builder.element('Writer', nest: item.subTitle);
        builder.element('Penciller', nest: item.subTitle);
      }

      builder.element('Genre', nest: 'Doujinshi');

      // 处理标签（支持中文化翻译）
      if (item.tags.isNotEmpty) {
        final tagsList = item.tags.map((tag) {
          if (!CbzConfig.translateTags) return tag;
          if (tag.contains(':')) {
            final parts = tag.split(':');
            final ns = parts[0];
            final key = parts[1];
            final transKey =
                TagsTranslation.translationTagWithNamespace(key, ns);
            final transNs =
                TagsTranslation.tagsCategoryTranslationsCN[ns] ?? ns;
            return "$transNs:$transKey";
          }
          return tag.translateTagsToCN;
        }).join(', ');

        builder.element('Tags', nest: tagsList);
      }

      builder.element('PageCount', nest: pageCount.toString());
      builder.element('Format', nest: 'Digital');
      builder.element('Manga', nest: 'YesAndRightToLeft');
      builder.element('AgeRating', nest: 'Adults Only 18+');

      // 添加原始链接用于溯源
      final webUrl = _resolveWebUrl(item);
      if (webUrl != null && webUrl.isNotEmpty) {
        builder.element('Web', nest: webUrl);
      }
    });

    return builder.buildDocument().toXmlString(pretty: true);
  }

  /// 解析各漫画平台的原始溯源链接（无官方/真实网页版则返回 null，不写入 ComicInfo）
  static String? _resolveWebUrl(DownloadedItem item) {
    if (item is DownloadedGallery) {
      // E-Hentai：官方真实画廊链接
      return item.gallery.link;
    } else if (item is DownloadedHitomiComic) {
      // Hitomi：官方真实画廊链接
      return item.link;
    } else if (item is DownloadedJmComic) {
      // 禁漫 JM：主站官方固定路径，便于未来统一维护替换
      return "https://18comic.vip/album/${item.comic.id}";
    } else if (item is NhentaiDownloadedComic) {
      // NHentai：官方固定主站路径
      final id = item.id.replaceFirst("nhentai", "");
      return "https://nhentai.net/g/$id/";
    } else if (item is DownloadedHtComic) {
      // 绅士漫画：官方固定主站路径
      return "https://www.wnacg.com/photos-index-aid-${item.comic.id}.html";
    } else if (item is CustomDownloadedItem) {
      // 第三方 JS 插件：若声明了有效 http(s) 网页主站，则拼接详情页
      final source = ComicSource.find(item.sourceKey);
      if (source != null &&
          (source.url.startsWith("http://") || source.url.startsWith("https://"))) {
        final base = source.url.endsWith('/')
            ? source.url.substring(0, source.url.length - 1)
            : source.url;
        return "$base/${item.comicId}";
      }
      return null;
    }
    // 哔咔 (Picacg) 等纯移动端无网页版平台，直接返回 null，不写入 <Web>
    return null;
  }
}
