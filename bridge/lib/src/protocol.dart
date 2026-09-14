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
  static const String nwcInfoContent =
      'get_info get_balance make_invoice pay_invoice';

  /// Metodi dichiarati nell'evento info NCC (kind 13198).
  static const String nccInfoContent =
      'list_channels open_channel close_channel';
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
