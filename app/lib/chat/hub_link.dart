// The device's one WebSocket to FamilyHub (docs/protocol.md "WebSocket").

/// What the sync engine needs from the hub connection; [HubConnection] is the real one.
abstract interface class HubLink {
  /// Hub → client frames, decoded.
  Stream<Map<String, Object?>> get events;

  /// true when a connection opens, false when it closes.
  Stream<bool> get connection;

  bool get connected;

  /// Sends a frame; false when not connected (the caller keeps it for later).
  bool send(Map<String, Object?> msg);

  /// Starts connecting and keeps reconnecting until [stop].
  Future<void> start();

  Future<void> stop();
}
