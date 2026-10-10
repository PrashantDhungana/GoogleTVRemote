import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_remote/remote_controller.dart';
import 'package:tv_remote/tv/discovery.dart';

class _MemoryStore implements SettingsStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;
}

const _living = TvDevice(name: 'TCL TV', host: '192.168.1.101', serviceName: 'TCL TV');
const _bedroom = TvDevice(name: 'Bedroom', host: '192.168.1.102');

void main() {
  late _MemoryStore store;

  // No identity can be made, so nothing touches the network.
  RemoteController newController() =>
      RemoteController(store: store, createIdentity: () async => throw StateError('offline'));

  setUp(() => store = _MemoryStore());

  test('remembers every TV chosen, and which one is in use', () async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.selectDevice(_living);
    await controller.selectDevice(_bedroom);
    expect(controller.savedDevices, [_living, _bedroom]);
    expect(controller.device, _bedroom);

    final reloaded = newController();
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.savedDevices, [_living, _bedroom]);
    expect(reloaded.device, _bedroom);
  });

  test('a TV saved before several TVs were remembered is kept', () async {
    store.values
      ..['device_name'] = 'TCL TV'
      ..['device_host'] = '192.168.1.101';
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.device, const TvDevice(name: 'TCL TV', host: '192.168.1.101'));
    expect(controller.savedDevices, [controller.device]);
    expect(jsonDecode(store.values['saved_tvs']!), [
      {'name': 'TCL TV', 'host': '192.168.1.101'},
    ]);
  });

  test('renamed TVs keep their name, also when picked from discovery again', () async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.selectDevice(_living);
    await controller.selectDevice(_bedroom);

    await controller.renameDevice(_living, '  Living room  ');
    expect(controller.savedDevices.first.name, 'Living room');
    // Not the current TV, so the top bar still shows the bedroom.
    expect(controller.device?.name, 'Bedroom');

    await controller.selectDevice(_living);
    expect(controller.device?.name, 'Living room');
    expect(controller.savedDevices, hasLength(2));

    await controller.renameDevice(controller.device!, 'Lounge');
    expect(controller.device?.name, 'Lounge');
    expect(store.values['device_name'], 'Lounge');

    // Blank names are ignored.
    await controller.renameDevice(controller.device!, '   ');
    expect(controller.device?.name, 'Lounge');

    final reloaded = newController();
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.device?.name, 'Lounge');
  });

  test('a saved TV found at a new address is followed there', () async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.selectDevice(_living);

    const moved = TvDevice(name: 'TCL TV', host: '192.168.1.150', serviceName: 'TCL TV');
    final saved = controller.savedMatch(moved);
    expect(saved?.host, '192.168.1.101');
    await controller.updateAddress(saved!, moved.host);
    expect(controller.device?.host, '192.168.1.150');
    expect(controller.savedDevices.single.host, '192.168.1.150');
    expect(store.values['device_host'], '192.168.1.150');
  });

  test('removing TVs: another one stays in use, removing the current one leaves none', () async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    await controller.selectDevice(_living);
    await controller.selectDevice(_bedroom);

    await controller.forgetDevice(_living);
    expect(controller.savedDevices, [_bedroom]);
    expect(controller.device, _bedroom);

    await controller.forgetDevice(_bedroom);
    expect(controller.savedDevices, isEmpty);
    expect(controller.device, isNull);
    expect(controller.status, ConnectionStatus.noDevice);
    expect(store.values.containsKey('device_host'), isFalse);
  });

  test('remembers the volume button and media control settings', () async {
    final controller = newController();
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.volumeKeysEnabled, isTrue);
    expect(controller.mediaControlsEnabled, isFalse);

    controller
      ..setVolumeKeysEnabled(false)
      ..setMediaControlsEnabled(true);
    await Future<void>.delayed(Duration.zero);

    final reloaded = newController();
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.volumeKeysEnabled, isFalse);
    expect(reloaded.mediaControlsEnabled, isTrue);
  });
}
