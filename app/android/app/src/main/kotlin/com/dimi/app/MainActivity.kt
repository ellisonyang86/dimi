package com.dimi.app

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 扫一扫页「去系统设置开启相机权限」用：跳转本应用的应用详情设置页
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dimi/settings"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openAppSettings") {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", packageName, null)
                    )
                )
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
