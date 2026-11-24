/// 平台安全存储键名集中定义（Android EncryptedSharedPreferences / iOS Keychain）。
///
/// install_guard 依据 [residualCredentialKeys] 在"新安装"时清空残留凭据：
/// iOS 的 Keychain 在 App 卸载后仍然保留，必须显式清理。
const workstationsStorageKey = 'dsh_solo_workstations_v1';
const legacyPairingStorageKey = 'dsh_solo_pairing_v2';
const deviceIdStorageKey = 'dsh_solo_device_id_v1';
const notifyPromptStorageKey = 'dsh_solo_notify_prompt_v1';

const residualCredentialKeys = <String>[
  workstationsStorageKey,
  legacyPairingStorageKey,
  deviceIdStorageKey,
  notifyPromptStorageKey,
];