/// 轻量双语词典（2026-10-28，零依赖 i18n）：
/// - `AppL10n.init(...)` 在 main() 里按系统语言初始化（仅区分 zh/en，en 之外一律中文，
///   与 Material 默认行为对齐）；
/// - 全 App 通过 `AppL10n.i.xxx` 取文案；带参数的用方法；
/// - 字段访问式（非字符串 key），IDE 可跳转、拼错即编译错。
///
/// 覆盖范围：App 全部界面文案（home/session/pair/dir browser）+ AppState 异常消息。
/// 电脑端配对页与插件 console 文案在 packages/agent/src/pairing.ts / index.ts 侧处理。
library;

/// 当前语言下的文案表（静态单例，App 启动时 init 一次）
class AppL10n {
  AppL10n._(this.isEn);

  final bool isEn;

  static late AppL10n i;

  /// 按系统语言初始化（languageCode == 'en' 用英文，其余中文）
  static void init(String languageCode) => i = AppL10n._(languageCode == 'en');

  String _t(String zh, String en) => isEn ? en : zh;

  // ---- 通用 ----
  String get cancel => _t('取消', 'Cancel');
  String get confirm => _t('确定', 'OK');
  String get add => _t('添加', 'Add');
  String get delete => _t('删除', 'Delete');
  String get retry => _t('重试', 'Retry');
  String get allow => _t('允许', 'Allow');
  String get deny => _t('拒绝', 'Deny');
  String get gotIt => _t('知道了', 'Got it');

  // ---- 主页 ----
  String get appTitle => _t('DSH-SOLO 遥控器', 'DSH-SOLO Remote');
  String get connectSettings => _t('连接设置', 'Connection settings');
  String get deviceTokenLabel => _t('设备令牌 deviceToken', 'Device token');
  String get scanPair => _t('扫码配对', 'Scan pairing QR');
  String get saveAndConnect => _t('保存并连接', 'Save & connect');
  String get qrRecognized => _t('二维码已识别，点击「连接」保存', 'QR code recognized — tap "Connect" to save');
  String get renameSession => _t('重命名会话', 'Rename session');
  String get sessionName => _t('会话名称', 'Session name');
  String renameFailed(Object e) => _t('重命名失败：$e', 'Rename failed: $e');
  String renameError(Object e) => _t('重命名异常：$e', 'Rename error: $e');
  String deleteConfirm(String title) =>
      _t('确定删除「$title」？电脑端会话记录将一并移除。', 'Delete "$title"? The desktop session will be removed as well.');
  String get deleted => _t('已删除', 'Deleted');
  String deleteFailed(Object e) => _t('删除失败：$e', 'Delete failed: $e');
  String deleteError(Object e) => _t('删除异常：$e', 'Delete error: $e');
  String pendingApprovals(int n) =>
      _t('有 $n 项待审批', '$n pending approval${n > 1 ? 's' : ''}');
  String get tapToReview => _t('点击查看并处理', 'Tap to review');
  String get newSession => _t('新会话', 'New session');
  String get desktopUnavailable => _t('未找到电脑插件，请核对设备令牌，并确认电脑端插件已启用', 'Desktop plugin unavailable. Check the device token and make sure the desktop plugin is enabled.');
  String get statusCheckingDesktop => _t('正在验证电脑', 'Verifying desktop');
  String get statusDesktopOffline => _t('电脑未连接', 'Desktop offline');
  String get statusOpen => _t('已连接', 'Connected');
  String get statusConnecting => _t('连接中', 'Connecting');
  String get statusAuthFailed => _t('鉴权失败', 'Auth failed');
  String get statusDisconnected => _t('已断开', 'Disconnected');
  String get statusIdle => _t('未连接', 'Offline');
  String get connectTitle => _t('连接到你的电脑', 'Connect to your PC');
  String get connectHint => _t('服务器地址已内置，设备令牌请扫码或手输',
      'Relay address is built in; scan the pairing QR or paste your token');
  String get connecting => _t('连接中…', 'Connecting…');
  String get connect => _t('连接', 'Connect');
  String authFailedDetail(Object err) => _t(
      '鉴权失败：$err（令牌可能已重置，请重新扫码）',
      'Auth failed: $err (token may have been reset — re-scan the pairing QR)');
  String connectFailedDetail(Object err) =>
      _t('连接失败：$err（将自动重试）', 'Connection failed: $err (will retry automatically)');
  String get pcDirectory => _t('电脑目录', 'PC directories');
  String get sessions => _t('会话', 'Sessions');
  String get noSessions => _t('暂无会话', 'No sessions yet');
  String get noSessionsHint =>
      _t('点击右下角「新会话」向电脑发送第一个任务', 'Tap "New session" to send your first task');
  String get fromPhone => _t('手机创建', 'From phone');
  String get fromPc => _t('电脑创建', 'From PC');
  String modelOf(String m) => _t('模型 $m', 'Model $m');
  String get sessionActions => _t('会话操作', 'Session actions');
  String get pcSessionNoDelete => _t('电脑端会话不可删', 'Desktop-created sessions cannot be deleted');
  String get running => _t('运行中', 'Running');
  String get browseDir => _t('浏览此目录', 'Browse this directory');
  String readFailed(Object e) => _t('读取失败：$e', 'Failed to read: $e');
  String get emptyDir => _t('（空目录）', '(empty)');
  String get emptyShort => _t('（空）', '(empty)');
  String pendingApprovalBanner(int n) =>
      _t('有 $n 项待审批', '$n pending approval${n > 1 ? 's' : ''}');

  // ---- 扫码配对 ----
  String get pairScanTitle => _t('扫码配对', 'Scan pairing QR');
  String get aimAtQr => _t('对准电脑端配对页上的二维码', 'Point at the QR code on the desktop pairing page');
  String cameraStartFailed(Object e) => _t('相机启动失败：$e', 'Camera failed to start: $e');
  String get cameraPermission =>
      _t('相机权限未授权，请在系统设置中允许「dsh_solo」使用相机后重试',
          'Camera permission denied. Allow "dsh_solo" to use the camera in system settings and retry');
  String get notPairingQr =>
      _t('不是配对二维码，请扫描电脑端配对页的二维码', 'Not a pairing QR — scan the one on the desktop pairing page');
  String get cameraError => _t('相机异常', 'Camera error');

  // ---- 会话页 ----
  String sessionTitle(String? sid) =>
      sid == null ? _t('新会话', 'New session') : _t('会话 $sid', 'Session $sid');
  String get gapBanner => _t('部分历史事件已丢失（超出缓冲）', 'Some history events were lost (buffer overflow)');
  String get firstTaskHint => _t('输入第一个任务开始', 'Type your first task to begin');
  String get noNewEvents => _t('暂无新事件', 'No new events yet');
  String get addAttachment => _t('添加附件', 'Add attachment');
  String get cameraOption => _t('拍照（压缩后 ≤10MB）', 'Camera (compressed ≤10MB)');
  String get galleryTitle => _t('从相册选择（压缩后 ≤10MB）', 'Photo gallery (compressed ≤10MB)');
  String get selectProject => _t('选择项目', 'Select project');
  String get selectProjectHint => _t('在电脑端已有项目下创建新会话，原会话保留', 'Create a new session in a desktop project. Existing sessions are kept.');
  String get noProjects => _t('暂无可用项目，请先在电脑端添加工作区', 'No projects available. Add a workspace on the desktop first.');
  String get projectsLoadFailed => _t('无法获取项目，请确认电脑插件已更新并保持在线', 'Cannot load projects. Update the desktop plugin and keep it online.');
  String get projectSelected => _t('项目已选择，发送消息后创建新会话', 'Project selected. Send a message to create the new session.');
  String get pcFile => _t('电脑文件', 'PC file');
  String get pcFileSubtitle => _t('从电脑工作区目录选择，不占手机流量',
      'Pick from the PC workspace — no phone bandwidth used');
  String get linkTitle => _t('在线文档链接', 'Online doc link');
  String get linkSubtitle => _t('粘贴 URL，由电脑端抓取', 'Paste a URL — fetched by the desktop agent');
  String get taskHint => _t('给电脑上的 AI 下任务…', 'Give the PC AI a task…');
  String get send => _t('发送', 'Send');
  String get invalidUrl => _t('请输入 http(s):// 开头的链接', 'Enter a link starting with http(s)://');
  String uploadFailed(Object e) => _t('上传失败：$e', 'Upload failed: $e');
  String sendFailed(Object e) => _t('发送失败：$e', 'Send failed: $e');
  String get unknownError => _t('未知错误', 'unknown error');
  String sendError(Object e) => _t('发送异常：$e', 'Send error: $e');
  String approveOk(bool approved) =>
      approved ? _t('已允许', 'Allowed') : _t('已拒绝', 'Denied');
  String approveFailed(Object e) => _t('响应失败：$e', 'Respond failed: $e');
  String approveError(Object e) => _t('响应异常：$e', 'Respond error: $e');
  String get allowedShort => _t('已允许', 'Allowed');
  String get denied => _t('已拒绝', 'Denied');
  String callingTool(String name) => _t('调用工具 $name', 'Call tool $name');
  String get toolFailed => _t('工具执行失败', 'Tool failed');
  String get toolResult => _t('工具返回', 'Tool result');
  String turnEnded(String reason) => _t('回合结束（$reason）', 'Turn ended ($reason)');
  String turnEndWith(String reason, String msg) =>
      _t('回合结束（$reason：$msg）', 'Turn ended ($reason: $msg)');
  String execTool(String detail) => _t('执行工具 $detail', 'Run tool $detail');
  String get toolDone => _t('工具执行完成', 'Tool finished');
  String pendingApprovalCard(String toolName) =>
      _t('待审批：[$toolName]', 'Approval needed: [$toolName]');
  String get taskDone => _t('任务完成', 'Task completed');
  String taskFailed(String? error) => (error == null || error.isEmpty)
      ? _t('任务失败', 'Task failed')
      : _t('任务失败：$error', 'Task failed: $error');
  String get thinking => _t('正在思考…', 'Thinking…');
  String get pickModel => _t('选择模型', 'Pick model');
  String get followDesktopDefault => _t('跟随电脑端默认', 'Follow desktop default');
  String get noModelsHint => _t('快照中没有模型列表（电脑端未连接或宿主模型目录未就绪）',
      'No models in the snapshot (desktop offline, or model catalog not ready)');
  String get pickPcFile => _t('选择电脑文件', 'Pick a PC file');
  String get noDirTreeHint =>
      _t('快照中没有目录树（电脑端未连接？）', 'No directory tree in the snapshot (desktop connected?)');
  String get sendFailedToast => _t('发送失败', 'Send failed');

  // —— 附件 ——
  String get attachmentPhoto => _t('拍照（压缩后 ≤10MB）', 'Camera (compressed ≤10MB)');
  String get attachmentGallery =>
      _t('从相册选择（压缩后 ≤10MB）', 'Photo library (compressed ≤10MB)');
  String get attachmentGalleryTitle => _t('从相册选择', 'Photo gallery');
  String get attachmentPcFile => _t('电脑文件', 'PC file');
  String get attachmentPcHint =>
      _t('从电脑工作区目录选择，不占手机流量', 'Pick from the PC workspace — no phone bandwidth');
  String get attachmentLink => _t('在线文档链接', 'Online doc link');
  String get attachmentLinkHint =>
      _t('粘贴 URL，由电脑端抓取', 'Paste a URL — fetched by the desktop');
  String get uploadFailedToastUnused => _t('上传失败', 'Upload failed'); // 保留占位
  String uploadRejected(Object e) => _t('上传被拒绝：$e', 'Upload rejected: $e');
  String maxAttachments(int n) =>
      _t('每条消息最多 $n 个附件', 'Max $n attachments per message');
  String fileTooLarge(double mb) => _t('文件 ${mb.toStringAsFixed(1)}MB 超过 10MB 上限',
      'File (${mb.toStringAsFixed(1)}MB) exceeds the 10MB limit');
  String get attachmentStillUploading =>
      _t('附件还在上传中', 'Attachments are still uploading');
  String get linkDialogTitle => _t('在线文档链接', 'Online doc link');
  String get linkHint => _t('https://…（网页 / 文档链接）', 'https://… (web / doc link)');
  String get pickPcFileTitle => _t('选择电脑文件', 'Pick a PC file');
  String get noDirTreeShort => _t('快照中没有目录树（电脑端未连接？）', 'No directory tree in the snapshot (desktop offline?)');
  String get linkPlaceholder => _t('https://…（网页 / 文档链接）', 'https://… (web / doc link)');

  // —— AppState 异常（无 BuildContext 也能用）——
  String get relayNotConnected => _t('relay 未连接', 'relay not connected');

  // ---- 事件渲染（会话页 _buildBubbles 用）----
  String toolCall(String name) => _t('调用工具 $name', 'Call tool $name');
  String toolStarted(String detail) => _t('执行工具 $detail', 'Run tool $detail');
  String get toolCompletedLabel => _t('工具执行完成', 'Tool finished');

  // —— 替换补充（2026-10-28 双语化时新增）——
  String get rename => _t('重命名', 'Rename');
  String get deleteSessionTitle => _t('删除会话', 'Delete session');
  String get cameraStartFailedShort => _t('相机启动失败', 'Camera failed to start');
  String cameraErrorDetail(Object code) => _t('相机异常：$code', 'Camera error: $code');
  String get chunkUploadFailed => _t('分块上传失败', 'Chunk upload failed');
  String get uploadNoPath => _t('上传未返回文件路径', 'Upload returned no file path');
  String get emptyEvent => _t('(空事件)', '(unknown event)');

  // —— 目录浏览 ——
  String loadFailed(Object e) => _t('读取失败：$e', 'Failed to read: $e');

  // —— Diff 查看器 ——
  String get changesTitle => _t('文件变更', 'File changes');
  String get noChanges => _t('本会话还没有文件变更', 'No file changes in this session');
  String get newFileTag => _t('新建', 'New');
  String get modifiedTag => _t('修改', 'Modified');
}
