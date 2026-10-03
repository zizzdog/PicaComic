import 'package:shared_preferences/shared_preferences.dart';

class CbzConfig {
  static const _keyAutoCbz = "custom_cbz_auto_package";
  static const _keyEmbedComicInfo = "custom_cbz_embed_comic_info";
  static const _keyTranslateTags = "custom_cbz_translate_tags_cn";
  static const _keyDeleteRaw = "custom_cbz_delete_raw_images";
  static const _keyEhDefaultNormal = "custom_eh_default_normal_download";
  static const _keyJmDefaultAll = "custom_jm_default_download_all";
  static const _keyPicaDefaultAll = "custom_pica_default_download_all";

  static bool autoCbz = true;
  static bool embedComicInfo = true;
  static bool translateTags = true;
  static bool deleteRaw = true;
  static bool ehDefaultNormalDownload = true;
  static bool jmDefaultDownloadAll = true;
  static bool picaDefaultDownloadAll = true;

  static bool _initialized = false;

  /// 初始化加载所有自定义配置
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final sp = await SharedPreferences.getInstance();
      autoCbz = sp.getBool(_keyAutoCbz) ?? true;
      embedComicInfo = sp.getBool(_keyEmbedComicInfo) ?? true;
      translateTags = sp.getBool(_keyTranslateTags) ?? true;
      deleteRaw = sp.getBool(_keyDeleteRaw) ?? true;
      ehDefaultNormalDownload = sp.getBool(_keyEhDefaultNormal) ?? true;
      jmDefaultDownloadAll = sp.getBool(_keyJmDefaultAll) ?? true;
      picaDefaultDownloadAll = sp.getBool(_keyPicaDefaultAll) ?? true;
      _initialized = true;
    } catch (_) {}
  }

  static Future<void> setAutoCbz(bool val) async {
    autoCbz = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyAutoCbz, val);
  }

  static Future<void> setEmbedComicInfo(bool val) async {
    embedComicInfo = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyEmbedComicInfo, val);
  }

  static Future<void> setTranslateTags(bool val) async {
    translateTags = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyTranslateTags, val);
  }

  static Future<void> setDeleteRaw(bool val) async {
    deleteRaw = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyDeleteRaw, val);
  }

  static Future<void> setEhDefaultNormalDownload(bool val) async {
    ehDefaultNormalDownload = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyEhDefaultNormal, val);
  }

  static Future<void> setJmDefaultDownloadAll(bool val) async {
    jmDefaultDownloadAll = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyJmDefaultAll, val);
  }

  static Future<void> setPicaDefaultDownloadAll(bool val) async {
    picaDefaultDownloadAll = val;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_keyPicaDefaultAll, val);
  }

  /// 序列化所有自定义设置为 Map，用于用户数据备份与 WebDAV 同步
  static Map<String, dynamic> toJson() => {
        "autoCbz": autoCbz,
        "embedComicInfo": embedComicInfo,
        "translateTags": translateTags,
        "deleteRaw": deleteRaw,
        "ehDefaultNormalDownload": ehDefaultNormalDownload,
        "jmDefaultDownloadAll": jmDefaultDownloadAll,
        "picaDefaultDownloadAll": picaDefaultDownloadAll,
      };

  /// 从备份数据或 WebDAV 同步中恢复自定义配置
  static Future<void> fromJson(Map<String, dynamic> json) async {
    if (json.containsKey("autoCbz")) {
      await setAutoCbz(json["autoCbz"] == true);
    }
    if (json.containsKey("embedComicInfo")) {
      await setEmbedComicInfo(json["embedComicInfo"] == true);
    }
    if (json.containsKey("translateTags")) {
      await setTranslateTags(json["translateTags"] == true);
    }
    if (json.containsKey("deleteRaw")) {
      await setDeleteRaw(json["deleteRaw"] == true);
    }
    if (json.containsKey("ehDefaultNormalDownload")) {
      await setEhDefaultNormalDownload(
          json["ehDefaultNormalDownload"] == true);
    }
    if (json.containsKey("jmDefaultDownloadAll")) {
      await setJmDefaultDownloadAll(json["jmDefaultDownloadAll"] == true);
    }
    if (json.containsKey("picaDefaultDownloadAll")) {
      await setPicaDefaultDownloadAll(json["picaDefaultDownloadAll"] == true);
    }
  }
}
