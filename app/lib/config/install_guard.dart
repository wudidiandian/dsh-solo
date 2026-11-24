/// 新安装残留凭据清理的平台入口（IO 实现 / Web 空实现）。
export 'install_guard_io.dart'
    if (dart.library.html) 'install_guard_web.dart';