/// Build defaults supplied by the shared distribution configuration.
const String defaultRelayUrl = String.fromEnvironment(
  'DSH_DEFAULT_RELAY', defaultValue: 'ws://127.0.0.1:8787/ws',
);
const String legacyRelayUrl = String.fromEnvironment('DSH_LEGACY_RELAY');
