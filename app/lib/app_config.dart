import 'package:shared_preferences/shared_preferences.dart';

/// Where the app finds your Supabase project.
///
/// Builds made by GitHub Actions have these baked in (see docs/SETUP.md).
/// Otherwise the app asks for them once on first launch.
class AppConfig {
  AppConfig(this.supabaseUrl, this.supabaseKey);

  final String supabaseUrl;
  final String supabaseKey;

  static const _builtInUrl = String.fromEnvironment('VIBE_SUPABASE_URL');
  static const _builtInKey = String.fromEnvironment('VIBE_SUPABASE_KEY');

  static bool get isBuiltIn => _builtInUrl.isNotEmpty && _builtInKey.isNotEmpty;

  static Future<AppConfig?> load() async {
    if (isBuiltIn) return AppConfig(_builtInUrl, _builtInKey);
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('supabase_url');
    final key = prefs.getString('supabase_key');
    if (url == null || key == null) return null;
    return AppConfig(url, key);
  }

  static Future<void> save(String url, String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supabase_url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    await prefs.setString('supabase_key', key.trim());
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supabase_url');
    await prefs.remove('supabase_key');
  }
}
