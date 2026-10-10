import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

@immutable
class TvDevice {
  const TvDevice({required this.name, required this.host, this.serviceName});

  /// Shown to the user; the TV's own name until the user renames it.
  final String name;
  final String host;

  /// The name the TV advertises on the network, which stays the same when its
  /// address changes. Null for TVs added by address.
  final String? serviceName;

  TvDevice copyWith({String? name, String? host}) =>
      TvDevice(name: name ?? this.name, host: host ?? this.host, serviceName: serviceName);

  Map<String, String> toJson() => {
    'name': name,
    'host': host,
    if (serviceName != null) 'service': serviceName!,
  };

  static TvDevice? fromJson(Object? json) => switch (json) {
    {'name': final String name, 'host': final String host} => TvDevice(
      name: name,
      host: host,
      serviceName: json['service'] as String?,
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is TvDevice &&
      other.name == name &&
      other.host == host &&
      other.serviceName == serviceName;

  @override
  int get hashCode => Object.hash(name, host, serviceName);
}

/// Finds TVs on the local network that advertise the Android TV Remote service.
class TvDiscovery extends ChangeNotifier {
  static const serviceType = '_androidtvremote2._tcp';

  final Map<String, TvDevice> _devices = {};
  nsd.Discovery? _discovery;
  bool _starting = false;
  bool _disposed = false;
  String? _error;

  List<TvDevice> get devices => _devices.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  bool get isScanning => _discovery != null || _starting;

  String? get error => _error;

  Future<void> start() async {
    if (isScanning) return;
    _starting = true;
    _error = null;
    _notify();
    try {
      // "androidtvremote2" is longer than the 15 characters RFC 6335 allows,
      // so the plugin's validation would reject it.
      nsd.disableServiceTypeValidation(true);
      final discovery = await nsd.startDiscovery(serviceType, ipLookupType: nsd.IpLookupType.v4);
      if (_disposed) {
        await nsd.stopDiscovery(discovery);
        return;
      }
      _discovery = discovery..addServiceListener(_onServiceChanged);
    } on nsd.NsdError catch (e) {
      _error = e.message;
    } on Exception catch (e) {
      // Discovery is best effort; the address can still be typed in.
      _error = '$e';
    } finally {
      _starting = false;
      _notify();
    }
  }

  Future<void> stop() async {
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) await nsd.stopDiscovery(discovery);
    _notify();
  }

  void _onServiceChanged(nsd.Service service, nsd.ServiceStatus status) {
    final name = service.name;
    if (name == null) return;
    if (status == nsd.ServiceStatus.found) {
      final host = service.addresses?.firstOrNull?.address ?? _trimDot(service.host);
      if (host == null || host.isEmpty) return;
      _devices[name] = TvDevice(name: name, host: host, serviceName: name);
    } else {
      _devices.remove(name);
    }
    _notify();
  }

  static String? _trimDot(String? host) =>
      host != null && host.endsWith('.') ? host.substring(0, host.length - 1) : host;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
