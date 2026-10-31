/// 配置存储后端条件导出：VM/Android 走 IO 实现，Web 走 localStorage 实现。
export 'config_store_io.dart' if (dart.library.html) 'config_store_web.dart';
