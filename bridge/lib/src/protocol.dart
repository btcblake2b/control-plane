/// Costanti e tipi del protocollo NWC/NCC (spec dal nodo dln-node).
///
/// // PERCHÉ: identiche al client Flutter — il bridge deve parlare la stessa
/// lingua (kind 23194/23195 per NWC, 23198/23199 per NCC, info 13194/13198).
class Protocol {
  Protocol._();

  static const int nwcRequestKind = 23194;
  static const int nwcResponseKind = 23195;
  static const int nwcNotificationKind = 23196;
  static const int nccRequestKind = 23198;
  static const int nccResponseKind = 23199;
  static const int nccNotificationKind = 23200;
  static const int infoKindNwc = 13194;
  static const int infoKindNcc = 13198;

  /// Metodi dichiarati nell'evento info NWC (kind 13194).
  ///
  /// // PERCHÉ (I1): aggiunti i metodi on-chain della spec dln-node, così
  /// app e futuri client vedono le capability reali del bridge.
  /// // PERCHÉ (I3): aggiunto `list_transactions` (movimenti del nodo da bkpr).
  /// // PERCHÉ (I3b): aggiunto `list_utxos` (output on-chain del nodo).
  /// // PERCHÉ (I3c): aggiunti `list_invoices` e `lookup_invoice` (storico e
  /// stato delle fatture, usati anche dal flusso di ricezione) e `list_pays` /
  /// `get_pending_htlcs` (pagamenti in uscita e HTLC in volo).
  /// // PERCHÉ (I3e): aggiunto `keysend` (pagamento a un nodo senza invoice).
  static const String nwcInfoContent =
      'get_info get_balance make_invoice pay_invoice '
      'make_new_address pay_onchain estimate_onchain_fees list_addresses '
      'list_transactions list_utxos list_invoices lookup_invoice '
      'list_pays get_pending_htlcs keysend';

  /// Metodi dichiarati nell'evento info NCC (kind 13198).
  /// // PERCHÉ (I3d): aggiunti `get_channel_fees`/`set_channel_fees`
  /// (policy di routing del canale: base, ppm, limiti HTLC).
  /// // PERCHÉ (I3e): aggiunti `get_node_stats` (economia + plugin),
  /// `list_forwards` (routing), `get_node_info` e `get_route` (rete).
  static const String nccInfoContent =
      'list_channels open_channel close_channel '
      'connect_peer disconnect_peer list_peers '
      'get_channel_fees set_channel_fees '
      'get_node_stats list_forwards get_node_info get_route';

  /// Notifiche annunciate negli eventi info (parità con la spec dln-node).
  static const List<String> nwcNotifications = [
    'payment_received',
    'payment_sent',
  ];
  static const List<String> nccNotifications = [
    'channel_opened',
    'channel_closed',
  ];
}

/// Errore applicativo risposto al client nel campo `error`.
class RpcError implements Exception {
  const RpcError(this.code, this.message);

  /// Codici dalla spec dln-node: RESTRICTED, NOT_IMPLEMENTED, OTHER.
  final String code;
  final String message;

  @override
  String toString() => 'RpcError($code): $message';
}

/// Notifica che il bridge pubblica verso i client (kind 23196 NWC / 23200 NCC).
///
/// // PERCHÉ: separa "cosa è cambiato sul nodo" (logica CLN, in NwcHandlers)
/// da "come lo si pubblica su Nostr" (BridgeService) — ognuno testabile da solo.
class BridgeNotification {
  const BridgeNotification({
    required this.type,
    required this.isNcc,
    required this.payload,
  });

  /// `payment_received`, `payment_sent`, `channel_opened`, `channel_closed`.
  final String type;

  /// True → kind NCC (23200), false → kind NWC (23196).
  final bool isNcc;
  final Map<String, dynamic> payload;
}
