/// Build defaults supplied by the shared distribution configuration.
const String defaultRelayUrl = String.fromEnvironment(
  'DSH_DEFAULT_RELAY',
  defaultValue: 'ws://127.0.0.1:8787/ws',
);
const String legacyRelayUrl = String.fromEnvironment('DSH_LEGACY_RELAY');

/// 内置国际（海外）网关节点，作为 App 内可选项；
/// 国内备案节点即 defaultRelayUrl（生产构建由 configure.mjs 注入）。
const String intlRelayUrl = String.fromEnvironment(
  'DSH_INTL_RELAY',
  defaultValue: 'wss://relay-global.example.com/ws',
);

/// 网关选择值：'cn' = 国内节点，'intl' = 国际节点（默认），null = 自定义（扫码指定）
typedef GatewayId = String?;

/// 由 relayUrl 反推网关选择（用于 UI 回显）；自定义地址返回 null。
GatewayId gatewayForUrl(String? url) {
  if (url == null || url.isEmpty) return 'intl';
  if (url == intlRelayUrl) return 'intl';
  if (url == defaultRelayUrl) return 'cn';
  return null;
}

/// 网关选择对应的 relay 地址；自定义（null）时返回 null 由调用方用实际 URL。
String? urlForGateway(GatewayId gateway) => switch (gateway) {
  'cn' => defaultRelayUrl,
  'intl' => intlRelayUrl,
  _ => null,
};
