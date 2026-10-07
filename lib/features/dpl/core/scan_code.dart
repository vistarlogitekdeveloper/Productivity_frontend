/// Repairs a pallet or SPD sticker payload whose pipe an RF gun lost.
///
/// A keyboard-wedge gun types the code as keystrokes, and `|` is a shifted
/// key whose position depends on the keyboard layout the gun is set to. On a
/// mismatched gun the plant's wheel labels — which carry no pipe — scan
/// perfectly, while every `MWP|PM26000012` arrives as `MWPPM26000012` or
/// `MWP\PM26000012` and is found nowhere. The server repairs it too; doing it
/// here as well means the app works against a server that predates that.
///
/// Only touched when what follows is unmistakably a pallet (or SPD pack)
/// number, so a wheel label can never be rewritten.
String repairStickerPayload(String raw) {
  final code = raw.trim();
  final flat = code.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  final pallet = _mangledPallet.firstMatch(flat);
  if (pallet != null) return 'MWP|${pallet.group(1)}';
  final pack = _mangledPack.firstMatch(flat);
  if (pack != null) return 'MWS|${pack.group(1)}';
  return code;
}

final _mangledPallet = RegExp(r'^MWP[^A-Z0-9]?((?:PM|SP|P|H|M)\d{6,})$');
final _mangledPack = RegExp(r'^MWS[^A-Z0-9]?(SP\d{6,})$');
