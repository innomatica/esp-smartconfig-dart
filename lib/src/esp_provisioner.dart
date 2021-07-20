import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:esp_smartconfig/esp_smartconfig.dart';
import 'package:esp_smartconfig/src/esp_provisioning_exception.dart';
import 'package:esp_smartconfig/src/esp_provisioning_protocol.dart';
import 'package:esp_smartconfig/src/esp_provisioning_response.dart';
import 'package:esp_smartconfig/src/esp_touch2.dart';
import 'package:loggerx/loggerx.dart';

final _logger = Logger.findOrCreate('esp_smartconfig');

/// Provisioner
class EspProvisioner {
  /// Protocol
  final EspProvisioningProtocol _protocol;

  /// Provisioning isolate
  Isolate? _isolate;

  /// Responses stream controller
  final _onResponseCtrl = StreamController<EspProvisioningResponse>();

  /// Stream of responses
  Stream<EspProvisioningResponse> get onResponse =>
      _onResponseCtrl.stream;

  /// Constructor for new EspProvisioner with desired [protocol]
  EspProvisioner._(this._protocol);

  /// EspProvisioner with EspTouch2 protocol
  factory EspProvisioner.espTouch2() {
    return EspProvisioner._(EspTouch2());
  }

  /// Start provisioning using [request]
  ///
  /// Provisioning will not stop automatically.
  /// It needs to be stopped manually by calling [stop] method
  Future<void> start(EspProvisioningRequest request) async {
    if (_isolate != null) {
      throw EspProvisioningException("Provisioning already runing");
    }

    final completer = Completer<void>();
    final rPort = ReceivePort();

    final worker =
        _EspWorker(request: request, logger: _logger, protocol: _protocol);

    rPort.listen((data) {
      if (data is _EspWorkerEvent) {
        switch (data.type) {
          case _EspWorkerEventType.init:
            (data.data as SendPort).send(worker);
            break;
          case _EspWorkerEventType.exception:
            stop();

            if (!completer.isCompleted) {
              completer.completeError(data);
            }
            break;
          case _EspWorkerEventType.started:
            completer.complete();
            break;
          case _EspWorkerEventType.response:
            _onResponseCtrl.sink.add(data.data);
            break;
        }
      } else {
        _logger.debug("Unhandled message from isolate: $data");
      }
    });

    _isolate = await Isolate.spawn(_provisioningIsolate, rPort.sendPort);
    return completer.future;
  }

  static void _provisioningIsolate(SendPort sPort) {
    final rPort = ReceivePort();

    rPort.listen((data) {
      if (data is _EspWorker) {
        _startProvisioning(data, sPort);
      }
    });

    sPort.send(_EspWorkerEvent.init(rPort.sendPort));
  }

  static void _startProvisioning(_EspWorker worker, SendPort sPort) async {
    final request = worker.request;
    final _logger = worker.logger;
    final protocol = worker.protocol;

    _logger.info("Provisioning starting...");

    _logger.debug("ssid ${request.ssid}");
    _logger.debug("bssid ${request.bssid}");
    _logger.debug("pwd ${request.password}");
    _logger.debug("rData ${request.reservedData}");
    _logger.debug("encriptionKey ${request.encryptionKey}");

    int p = 0;
    RawDatagramSocket? _socket;

    final ports = protocol.ports;
    for (; p < ports.length; p++) {
      try {
        _logger.debug("Creating UDP socket on port ${ports[p]}");

        _socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          ports[p],
          reuseAddress: true,
        );

        _socket.broadcastEnabled = true;

        _socket.listen(
          (event) {
            if (event != RawSocketEvent.read) {
              return;
            }

            final pkg = _socket!.receive();

            if (pkg == null) {
              return;
            }

            try {
              final response = protocol.receive(pkg.data);

              if(response == null) {
                // Same response already received. Ignoring...
                return;
              }

              _logger.info(
                  "Received response, device bssid: ${response.deviceBssidString}");
              
              sPort.send(_EspWorkerEvent.result(response));
            } catch (e) {
              _logger.warning("Received invalid EspTouch reponse: $e");
            }
          },
          onError: (err, s) {
            _logger.error("Socket error", err, s);
            sPort.send(_EspWorkerEvent.exception("Socket error: $err"));
          },
          cancelOnError: true,
        );

        _logger.debug(
            "UDP socket on port ${ports[p]} created");
        break;
      } catch (e) {
        sPort.send(_EspWorkerEvent.exception("UDP port bind failed: $e"));
        return;
      }
    }

    if (_socket == null) {
      final ev = _EspWorkerEvent.exception("Create UDP socket failed");
      _logger.error(ev.data);
      sPort.send(ev);
      return;
    }

    protocol.setup(_socket, p, request, _logger);

    int stepMs = 5;
    Timer.periodic(
        Duration(milliseconds: stepMs), (t) => protocol.loop(stepMs, t));

    _logger.info("Provisioning started");

    sPort.send(_EspWorkerEvent.started());
  }

  /// Stop provisioning previously started with [start] method
  void stop() {
    if (_isolate == null) {
      _logger.debug("Isolate already destroyed");
    } else {
      _logger.debug("Destroying isolate");
      _isolate!.kill(priority: Isolate.immediate);
      _isolate = null;
    }

    if (!_onResponseCtrl.isClosed) {
      _onResponseCtrl.close();
    }

    _logger.info("Provisioning stopped");
  }
}

class _EspWorker {
  final EspProvisioningRequest request;
  final Logger logger;
  final EspProvisioningProtocol protocol;

  const _EspWorker({
    required this.request,
    required this.logger,
    required this.protocol,
  });
}

enum _EspWorkerEventType {
  init,
  exception,
  started,
  response,
}

class _EspWorkerEvent {
  final _EspWorkerEventType type;
  final dynamic data;

  const _EspWorkerEvent(this.type, [this.data]);

  factory _EspWorkerEvent.init(SendPort port) {
    return _EspWorkerEvent(_EspWorkerEventType.init, port);
  }

  factory _EspWorkerEvent.exception(
    String message,
  ) {
    return _EspWorkerEvent(
        _EspWorkerEventType.exception, EspProvisioningException(message));
  }

  factory _EspWorkerEvent.started() {
    return _EspWorkerEvent(_EspWorkerEventType.started);
  }

  factory _EspWorkerEvent.result(EspProvisioningResponse result) {
    return _EspWorkerEvent(_EspWorkerEventType.response, result);
  }
}
