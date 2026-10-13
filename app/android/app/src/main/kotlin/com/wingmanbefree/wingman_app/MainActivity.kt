package com.wingmanbefree.wingman_app

import android.app.Activity
import com.wingmanbefree.wingman_app.grasp.GraspChannelCoordinator
import io.flutter.plugins.webviewflutter.WebViewFlutterPlugin
import androidx.activity.result.contract.ActivityResultContracts
import com.wingmanbefree.wingman_app.filepicker.FilePickerPlatformContract
import com.wingmanbefree.wingman_app.filepicker.WebViewFilePickerCoordinator
import com.wingmanbefree.wingman_app.fips.FipsPlatformContract
import com.wingmanbefree.wingman_app.fips.FipsRuntimeCoordinator
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var graspCoordinator: GraspChannelCoordinator? = null
    private var graspChannel: MethodChannel? = null
    private var fipsCoordinator: FipsRuntimeCoordinator? = null
    private var fipsChannel: MethodChannel? = null
    private var filePickerCoordinator: WebViewFilePickerCoordinator? = null
    private var filePickerChannel: MethodChannel? = null

    private val vpnConsentLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { activityResult ->
        fipsCoordinator?.onVpnConsentResult(activityResult.resultCode == Activity.RESULT_OK)
    }

    private val diagnosticsExportLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("text/plain"),
    ) { uri -> fipsCoordinator?.onDiagnosticsDestination(uri?.toString()) }

    private val openDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> filePickerCoordinator?.complete(uri?.toString()) }

    private val openMultipleDocumentsLauncher = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris -> filePickerCoordinator?.complete(uris.map { it.toString() }) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "au.com.otherstuff.wingman/drive").setMethodCallHandler { call, result ->
            if (call.method != "open") { result.notImplemented() } else {
                try {
                    val file = java.io.File(call.arguments as String)
                    val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.drivefiles", file)
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "application/octet-stream"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(android.content.Intent.createChooser(intent, "Save or open file")); result.success(mapOf("localSaved" to true, "exportPresented" to true))
                } catch (_: Exception) { result.error("export_failed", "Cannot export file", null) }
            }
        }
        val nativeGraspChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GraspChannelCoordinator.CHANNEL)
        graspChannel = nativeGraspChannel
        graspCoordinator = GraspChannelCoordinator(nativeGraspChannel) { id ->
            (flutterEngine.plugins.get(WebViewFlutterPlugin::class.java) as? WebViewFlutterPlugin)
                ?.instanceManager?.getInstance(id)
        }.also { nativeGraspChannel.setMethodCallHandler(it) }
        val coordinator = FipsRuntimeCoordinator(
            this,
            launchConsent = { vpnConsentLauncher.launch(it) },
            launchDiagnosticsExport = { diagnosticsExportLauncher.launch(it) },
        )
        fipsCoordinator = coordinator
        fipsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FipsPlatformContract.CHANNEL,
        ).also { it.setMethodCallHandler(coordinator) }

        val pickerCoordinator = WebViewFilePickerCoordinator(
            launchSingleDocument = openDocumentLauncher::launch,
            launchMultipleDocuments = openMultipleDocumentsLauncher::launch,
        )
        filePickerCoordinator = pickerCoordinator
        filePickerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FilePickerPlatformContract.CHANNEL,
        ).also { it.setMethodCallHandler(pickerCoordinator) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        graspChannel?.setMethodCallHandler(null)
        graspChannel = null
        graspCoordinator?.destroy()
        graspCoordinator = null
        filePickerChannel?.setMethodCallHandler(null)
        filePickerChannel = null
        filePickerCoordinator?.destroy()
        filePickerCoordinator = null
        fipsChannel?.setMethodCallHandler(null)
        fipsChannel = null
        fipsCoordinator?.destroy()
        fipsCoordinator = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        filePickerCoordinator?.destroy()
        filePickerCoordinator = null
        fipsCoordinator?.destroy()
        fipsCoordinator = null
        graspCoordinator?.destroy()
        graspCoordinator = null
        super.onDestroy()
    }
}
