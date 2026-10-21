import 'dart:io';

/// This device's IPv4 addresses that other devices on the local network can
/// reach, best first: Wi-Fi and hotspot before Ethernet, private ranges
/// before anything else. Mobile data, VPN and virtual adapters come last
/// (or are left out when a better address exists).
Future<List<String>> lanAddresses() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } catch (_) {
    return const [];
  }
  final ranked = <(int, String)>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) continue;
      ranked.add((_score(interface.name, address.address), address.address));
    }
  }
  ranked.sort((a, b) => b.$1.compareTo(a.$1));
  final good = ranked.where((r) => r.$1 > 0).toList();
  return [for (final r in good.isNotEmpty ? good : ranked) r.$2];
}

int _score(String interfaceName, String ip) {
  final name = interfaceName.toLowerCase();
  var score = _isPrivate(ip) ? 10 : 0;
  if (_matches(name, const ['wlan', 'wi-fi', 'wifi', 'wireless', 'en0'])) {
    score += 6;
  } else if (_matches(name, const ['ap', 'swlan', 'softap', 'hotspot'])) {
    score += 5;
  } else if (_matches(name, const ['eth', 'ethernet', 'en'])) {
    score += 4;
  }
  if (_matches(name, const [
    'rmnet',
    'ccmni',
    'pdp',
    'wwan',
    'cellular',
    'tun',
    'tap',
    'ppp',
    'ipsec',
    'utun',
    'vpn',
    'wireguard',
    'wg',
    'dummy',
    'docker',
    'veth',
    'virbr',
    'vmnet',
    'vbox',
    'virtualbox',
    'vethernet',
    'hyper-v',
    'wsl',
    'zerotier',
    'tailscale',
    'clat',
    'v4-',
  ])) {
    score -= 20;
  }
  return score;
}

bool _matches(String name, List<String> prefixes) =>
    prefixes.any((p) => name.startsWith(p) || name.contains(' $p'));

bool _isPrivate(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.contains(null)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}
