/// Which addresses this machine can be asked for, and which it may answer on.
///
/// A port of the sync server's console/lib/src/addresses.dart, which is where
/// this ordering was worked out — a desktop with Docker on it holds several
/// private addresses and only some of them lead anywhere. Kept as one file so
/// there is one answer to "which interface first", not two that drift.
///
/// What is *not* in that file is [bindRefusal]. This port serves the entire
/// library in plaintext, so a bind wider than loopback without a bearer token
/// is refused here in the same terms scripts/install.sh refuses it.
library;

import 'dart:io';

/// One address this machine answers on, and the interface it sits on.
class LanAddr {
  const LanAddr(this.ip, [this.iface = '']);

  final String ip;
  final String iface;

  /// The interface name is what makes the choice obvious to somebody who has
  /// never thought about networking: 10.10.20.1 and 172.17.0.1 look equally
  /// plausible until one of them says docker0 beside it.
  @override
  String toString() => iface.isEmpty ? ip : '$ip ($iface)';

  @override
  bool operator ==(Object other) =>
      other is LanAddr && other.ip == ip && other.iface == iface;

  @override
  int get hashCode => Object.hash(ip, iface);
}

/// Whether this is one of the address blocks reserved for private networks —
/// the ones another machine in the same house can reach and the wider internet
/// cannot.
bool privateV4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final parts = address.address.split('.').map(int.parse).toList();
  if (parts.length != 4) return false;
  return parts[0] == 10 ||
      (parts[0] == 172 && parts[1] >= 16 && parts[1] < 32) ||
      (parts[0] == 192 && parts[1] == 168);
}

/// Every private IPv4 this machine answers on, likeliest first.
///
/// The virtual ones are sorted to the back rather than dropped, because
/// somebody running this inside a container may well need the one on the
/// bridge — but nobody should be handed it first.
Future<List<LanAddr>> lanAddrs() async {
  final List<LanAddr> found = [];
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in interfaces) {
      for (final address in iface.addresses) {
        if (privateV4(address)) found.add(LanAddr(address.address, iface.name));
      }
    }
  } on OSError {
    // A machine with no networking at all still has a console worth opening;
    // it just has nothing wider than loopback to offer.
    return const [];
  }
  return orderLanAddrs(found);
}

/// Moves the virtual interfaces to the back, leaving the order the system gave
/// everything else — that order is the machine's own opinion about which
/// network matters, and this has no better one.
List<LanAddr> orderLanAddrs(List<LanAddr> addrs) => [
  ...addrs.where((a) => !virtualIface(a.iface)),
  ...addrs.where((a) => virtualIface(a.iface)),
];

/// Recognises the interfaces that exist for software on this machine to talk
/// to itself. Named by prefix because that is how the tools that create them
/// name them.
bool virtualIface(String name) => const [
  'docker',
  'br-',
  'bridge',
  'veth',
  'virbr',
  'vboxnet',
  'vmnet',
  'tun',
  'tap',
].any(name.startsWith);

/// What the Address section offers.
///
/// The two non-addresses first, because they are the two decisions: only this
/// machine, or every interface on it. Then every address the machine actually
/// answers on.
List<LanAddr> bindHosts(String current, List<LanAddr> lan) {
  final hosts = [const LanAddr('127.0.0.1'), const LanAddr('0.0.0.0'), ...lan];
  if (hosts.any((h) => h.ip == current) || current.isEmpty) return hosts;
  // A hostname, or an address on an interface that is down: keep it rather
  // than silently rebinding a running server to something else.
  return [LanAddr(current), ...hosts];
}

/// Whether this address is one machine's own business.
///
/// The same three spellings scripts/install.sh lets through without a token.
bool loopbackHost(String host) =>
    const ['127.0.0.1', '::1', 'localhost'].contains(host);

/// Why a wider bind is refused, or null when it is allowed.
///
/// This port answers with the whole library, in plaintext, over HTTP: nothing
/// here is encrypted and the only credential is the bearer token. Binding it
/// where another machine can route to it without one publishes somebody's
/// entire reading — so this is a refusal rather than a warning, which is what
/// scripts/install.sh does with the same choice and what server.py warns about
/// at startup. Loopback and ::1 stay allowed with no token: that is one
/// machine talking to itself.
String? bindRefusal(String host, {required bool hasToken, String? configFile}) {
  if (hasToken || loopbackHost(host)) return null;
  return 'Refusing to bind $host without a bearer token. That address serves '
      'the entire library, in plaintext, to anything that can reach it. '
      'Generate one with  openssl rand -base64 32  and put it in '
      '${configFile ?? 'the config file'} as "bearer_token", then try again.';
}
