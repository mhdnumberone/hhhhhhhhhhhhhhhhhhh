package com.zeroone.theconduit

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.ExecutionException

class MainActivity : FlutterActivity() {
    private val CAMERA_CHANNEL_NAME = "com.zeroone.theconduit/camera"
    private val FILES_CHANNEL_NAME = "com.zeroone.theconduit/files"
    private val TAG = "MainActivity"

    private lateinit var cameraExecutor: ExecutorService
    private var imageCapture: ImageCapture? = null
    private var cameraProvider: ProcessCameraProvider? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cameraExecutor = Executors.newSingleThreadExecutor()

        // Camera Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL_NAME).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "takePicture" -> {
                    val lensDirectionArg = call.argument<String>("lensDirection") ?: "back"
                    if (allPermissionsGranted()) {
                        startCamera(lensDirectionArg) { success ->
                            if (success) {
                                takePhoto(result)
                            } else {
                                result.error("CAMERA_START_FAILED", "Failed to start camera.", null)
                            }
                        }
                    } else {
                        // This should ideally be handled by requesting permissions from Flutter side first
                        // using permission_handler before calling this native method.
                        result.error("PERMISSION_DENIED", "Camera permissions not granted.", null)
                    }
                }
                "disposeCamera" -> {
                    disposeCameraResources()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Files Channel (from previous implementation, ensure it remains functional)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL_NAME).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "listFiles" -> {
                    val path = call.argument<String>("path") ?: context.filesDir.absolutePath
                    Log.d(TAG, "listFiles called for path: $path")
                    try {
                        val directory = File(path)
                        if (!directory.exists() || !directory.isDirectory) {
                            result.error("INVALID_PATH", "Path is not a valid directory or does not exist.", null)
                            return@setMethodCallHandler
                        }
                        val filesList = directory.listFiles()?.mapNotNull { file ->
                            mapOf(
                                "name" to file.name,
                                "path" to file.absolutePath,
                                "isDirectory" to file.isDirectory,
                                "size" to file.length(),
                                "lastModified" to file.lastModified()
                            )
                        } ?: emptyList()
                        result.success(mapOf("files" to filesList, "path" to directory.absolutePath))
                    } catch (e: Exception) {
                        Log.e(TAG, "Error listing files", e)
                        result.error("LIST_FILES_FAILED", "Failed to list files.", e.localizedMessage)
                    }
                }
                "executeShellCommand" -> {
                    val command = call.argument<String>("command")
                    val commandArgs = call.argument<List<String>>("args") ?: emptyList()
                    Log.d(TAG, "executeShellCommand called: $command with args: $commandArgs")

                    val whiteListedCommands = mapOf(
                        "pwd" to listOf("pwd"),
                        "ls" to listOf("ls")
                    )

                    if (command != null && whiteListedCommands.containsKey(command)) {
                        val fullCommandArray = whiteListedCommands[command]!!.toMutableList()
                        try {
                            val process = ProcessBuilder(fullCommandArray).start()
                            val stdout = process.inputStream.bufferedReader().readText()
                            val stderr = process.errorStream.bufferedReader().readText()
                            process.waitFor()
                            val exitCode = process.exitValue()
                            result.success(mapOf(
                                "stdout" to stdout,
                                "stderr" to stderr,
                                "exitCode" to exitCode
                            ))
                        } catch (e: IOException) {
                            Log.e(TAG, "Error executing shell command", e)
                            result.error("EXECUTION_FAILED", "IO error executing command", e.localizedMessage)
                        } catch (e: InterruptedException) {
                            Log.e(TAG, "Shell command interrupted", e)
                            result.error("EXECUTION_INTERRUPTED", "Command execution interrupted", e.localizedMessage)
                        }
                    } else {
                        Log.w(TAG, "Command not whitelisted or null: $command")
                        result.error("COMMAND_NOT_WHITELISTED", "The command 	'$command	' is not allowed.", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startCamera(lensDirection: String, callback: (Boolean) -> Unit) {
        val cameraProviderFuture: ListenableFuture<ProcessCameraProvider> = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()
                val cameraSelector = if (lensDirection.equals("front", ignoreCase = true)) {
                    CameraSelector.DEFAULT_FRONT_CAMERA
                } else {
                    CameraSelector.DEFAULT_BACK_CAMERA
                }

                imageCapture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY) // Or CAPTURE_MODE_MAXIMIZE_QUALITY
                    .build()

                // Unbind use cases before rebinding
                cameraProvider?.unbindAll()

                // Bind use cases to camera
                // A Preview use case is often needed for the camera to initialize correctly, even if not displayed.
                // However, for background capture, we might not need a surface provider for Preview.
                // For simplicity in a background service context, we focus on ImageCapture.
                // If issues arise, a dummy Preview might be needed.
                cameraProvider?.bindToLifecycle(
                    this, // LifecycleOwner
                    cameraSelector,
                    imageCapture
                    // preview // If a Preview use case is added
                )
                Log.d(TAG, "Camera started successfully with lens: $lensDirection")
                callback(true)
            } catch (exc: ExecutionException) {
                Log.e(TAG, "Use case binding failed (ExecutionException)", exc)
                callback(false)
            } catch (exc: InterruptedException) {
                Log.e(TAG, "Use case binding failed (InterruptedException)", exc)
                callback(false)
            } catch (exc: Exception) {
                Log.e(TAG, "Use case binding failed (Exception)", exc)
                callback(false)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun takePhoto(result: MethodChannel.Result) {
        val imageCapture = this.imageCapture ?: run {
            result.error("CAMERA_NOT_INITIALIZED", "ImageCapture is null.", null)
            return
        }

        val photoFile = createFile(applicationContext, "jpg")

        val outputOptions = ImageCapture.OutputFileOptions.Builder(photoFile).build()

        imageCapture.takePicture(
            outputOptions,
            ContextCompat.getMainExecutor(this),
            object : ImageCapture.OnImageSavedCallback {
                override fun onError(exc: ImageCaptureException) {
                    Log.e(TAG, "Photo capture failed: ${exc.message}", exc)
                    result.error("CAPTURE_FAILED", "Photo capture failed: ${exc.message}", exc.toString())
                }

                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val savedUri = output.savedUri ?: Uri.fromFile(photoFile)
                    Log.d(TAG, "Photo capture succeeded: ${savedUri.path}")
                    result.success(savedUri.path) // Return the absolute path
                }
            }
        )
    }

    private fun createFile(context: Context, extension: String): File {
        val sdf = SimpleDateFormat("yyyyMMdd_HHmmssSSS", Locale.US)
        val mediaDir = context.externalMediaDirs.firstOrNull()?.let {
            File(it, "CameraX_Images").apply { mkdirs() } }
        val dir = if (mediaDir != null && mediaDir.exists()) mediaDir else context.filesDir
        return File(dir, "IMG_${sdf.format(Date())}.$extension")
    }

    private fun allPermissionsGranted() = REQUIRED_PERMISSIONS.all {
        ContextCompat.checkSelfPermission(baseContext, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun disposeCameraResources() {
        cameraProvider?.unbindAll()
        imageCapture = null
        cameraProvider = null
        Log.d(TAG, "Camera resources disposed")
    }

    override fun onDestroy() {
        super.onDestroy()
        disposeCameraResources()
        if (::cameraExecutor.isInitialized) cameraExecutor.shutdown()
    }

    companion object {
        private val REQUIRED_PERMISSIONS = arrayOf(Manifest.permission.CAMERA)
    }
}
