import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/utils/cbz_config.dart';
import 'package:pica_comic/utils/translations.dart';

class CustomSettingsPage extends StatefulWidget {
  const CustomSettingsPage({super.key});

  @override
  State<CustomSettingsPage> createState() => _CustomSettingsPageState();
}

class _CustomSettingsPageState extends State<CustomSettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("CBZ 与快捷下载设置".tl),
      ),
      body: ListView(
        children: [
          _buildCategoryHeader("CBZ 归档与元数据".tl),
          SwitchListTile(
            title: Text("下载后自动打包为 CBZ".tl),
            subtitle: Text("下载完成后直接生成根目录 .cbz 文件，消除繁杂子文件夹".tl),
            value: CbzConfig.autoCbz,
            onChanged: (val) async {
              await CbzConfig.setAutoCbz(val);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: Text("打包后删除原始散装图片".tl),
            subtitle: Text("释放碎片小文件占用的存储空间".tl),
            value: CbzConfig.deleteRaw,
            onChanged: CbzConfig.autoCbz
                ? (val) async {
                    await CbzConfig.setDeleteRaw(val);
                    setState(() {});
                  }
                : null,
          ),
          SwitchListTile(
            title: Text("嵌入 ComicInfo.xml 元数据".tl),
            subtitle: Text("在 CBZ 根目录生成标准元数据，供 Komga / Kavita / 阅读器刮削".tl),
            value: CbzConfig.embedComicInfo,
            onChanged: CbzConfig.autoCbz
                ? (val) async {
                    await CbzConfig.setEmbedComicInfo(val);
                    setState(() {});
                  }
                : null,
          ),
          SwitchListTile(
            title: Text("ComicInfo 使用中文翻译标签".tl),
            subtitle: Text("基于 EhTagTranslation 词库将标签汉化（如 female:maid -> 女性:女仆）".tl),
            value: CbzConfig.translateTags,
            onChanged: (CbzConfig.autoCbz && CbzConfig.embedComicInfo)
                ? (val) async {
                    await CbzConfig.setTranslateTags(val);
                    setState(() {});
                  }
                : null,
          ),
          const Divider(),
          _buildCategoryHeader("快捷下载行为设置".tl),
          SwitchListTile(
            title: Text("E-Hentai 默认普通下载".tl),
            subtitle: Text("点击下载按钮直接加入下载队列，不再弹出普通/归档选择框".tl),
            value: CbzConfig.ehDefaultNormalDownload,
            onChanged: (val) async {
              await CbzConfig.setEhDefaultNormalDownload(val);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: Text("禁漫 (JM) 默认全选章节".tl),
            subtitle: Text("点击下载按钮时自动全选未下载的话数，跳过选话弹窗".tl),
            value: CbzConfig.jmDefaultDownloadAll,
            onChanged: (val) async {
              await CbzConfig.setJmDefaultDownloadAll(val);
              setState(() {});
            },
          ),
          SwitchListTile(
            title: Text("哔咔 (Picacg) 默认全选章节".tl),
            subtitle: Text("点击下载按钮时自动全选未下载的话数，跳过选话弹窗".tl),
            value: CbzConfig.picaDefaultDownloadAll,
            onChanged: (val) async {
              await CbzConfig.setPicaDefaultDownloadAll(val);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
