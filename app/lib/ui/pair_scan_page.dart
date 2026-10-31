/// 扫码配对页：扫描电脑端配对页展示的二维码，
/// 解析 `dshsolo://pair?relay=...&token=...` 并把结果返回给设置页回填。
/// 非 dshsolo:// 协议的码 toast 提示后留在页面继续扫。
/// 相机启动失败（权限被拒/被占用等）不黑屏，显示可操作的错误面板。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_l10n.dart';

/// 一次成功扫码的解析结果
typedef PairInfo = ({String relayUrl, String token});

/// 解析配对二维码内容；非 `dshsolo://pair` 协议或缺参返回 null。
PairInfo? parsePairUri(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'dshsolo' || uri.host != 'pair') return null;
  final relay = uri.queryParameters['relay'];
  final token = uri.queryParameters['token'];
  if (relay == null || relay.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  return (relayUrl: relay, token: token);
}

class PairScanPage extends StatefulWidget {
  const PairScanPage({super.key});

  @override
  State<PairScanPage> createState() => _PairScanPageState();
}

class _PairScanPageState extends State<PairScanPage> {
  /// autoStart disabled: the widget would otherwise call start() concurrently
  /// with our own call below; the second start hits the ongoing permission
  /// request, latches the widget into its error state, and the preview never
  /// recovers even after the user grants the permission.
  final MobileScannerController _controller =
      MobileScannerController(autoStart: false);
  bool _done = false;
  DateTime _lastErrorAt = DateTime.fromMillisecondsSinceEpoch(0);
  /// 相机启动失败信息（null = 预览正常）；页面显示错误面板而非黑屏
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  /// 主动 start 以捕获启动异常（权限被拒、相机被占用等都会在这里抛出）。
  Future<void> _startCamera() async {
    try {
      await _controller.start();
    } on MobileScannerException catch (e) {
      if (!mounted) return;
      setState(() => _startupError = _describeError(e));
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _startupError = AppL10n.i.cameraStartFailed(e));
      return;
    }
    if (!mounted) return;
    // Some failure paths return without throwing (e.g. a latched
    // permissionDenied error makes start() a silent no-op), so inspect the
    // resulting controller state instead of relying on exceptions alone.
    final state = _controller.value;
    final stateError = state.error;
    if (!state.isRunning && stateError != null) {
      setState(() => _startupError = _describeError(stateError));
      return;
    }
    setState(() => _startupError = null);
  }

  String _describeError(MobileScannerException e) {
    if (e.errorCode == MobileScannerErrorCode.permissionDenied) {
      return AppL10n.i.cameraPermission;
    }
    return AppL10n.i.cameraStartFailed(e.errorDetails?.message ?? e.errorCode.name);
  }

  @override
  void dispose() {
    // 先停再 dispose（7.x dispose 不会自动 stop），串行 fire-and-forget；
    // 页面即将销毁，无需等待结果。
    unawaited(_controller.stop().whenComplete(_controller.dispose));
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || !mounted) return;
    for (final barcode in capture.barcodes) {
      final info = parsePairUri(barcode.rawValue);
      if (info != null) {
        _done = true;
        Navigator.of(context).pop(info);
        return;
      }
    }
    // Throttle the "not a pair code" toast: the camera fires callbacks continuously
    final hasRaw = capture.barcodes.any((b) => (b.rawValue ?? '').isNotEmpty);
    final now = DateTime.now();
    if (hasRaw && now.difference(_lastErrorAt) > const Duration(seconds: 2)) {
      _lastErrorAt = now;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(AppL10n.i.notPairingQr),
          duration: const Duration(seconds: 2),
        ));
    }
  }

  /// 相机启动失败面板：错误说明 + 重试；fallback 用于 widget 层错误兜底
  Widget _errorPanel({String? fallback}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 56, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              _startupError ?? fallback ?? AppL10n.i.cameraStartFailedShort,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() => _startupError = null);
                _startCamera();
              },
              icon: const Icon(Icons.refresh),
              label: Text(AppL10n.i.retry),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(AppL10n.i.pairScanTitle)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 启动失败时仍挂载（保持 controller 状态），但用错误面板盖住黑屏；
          // errorBuilder 兜底 widget 层错误，统一渲染我们的错误面板
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) =>
                _errorPanel(fallback: AppL10n.i.cameraErrorDetail(error.errorCode.name)),
          ),
          if (_startupError != null)
            ColoredBox(color: Colors.black87, child: _errorPanel()),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              child: Text(
                AppL10n.i.aimAtQr,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
