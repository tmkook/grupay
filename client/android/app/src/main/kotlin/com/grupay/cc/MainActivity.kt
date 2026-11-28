package com.grupay.cc

import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.net.URL
import java.security.DigestInputStream
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "grupay/session")
            .setMethodCallHandler { call, result ->
                if (call.method == "foregroundNotice") {
                    android.widget.Toast.makeText(this, call.arguments as String, android.widget.Toast.LENGTH_LONG).show()
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method == "model") {
                    result.success("${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim())
                    return@setMethodCallHandler
                }
                if (call.method != "snapshot") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        if (call.argument<Boolean>("flush") == true) android.webkit.CookieManager.getInstance().flush()
                        val file = File(applicationInfo.dataDir, "app_webview/Default/Cookies")
                        val flags = android.database.sqlite.SQLiteDatabase.OPEN_READONLY or android.database.sqlite.SQLiteDatabase.NO_LOCALIZED_COLLATORS
                        val query = """SELECT count(*),count(CASE WHEN name IN ('sid_tt','sessionid','sessionid_ss') THEN 1 END),
                            min(CASE WHEN name IN ('sid_tt','sessionid','sessionid_ss') AND expires_utc>0
                              THEN expires_utc/1000000-11644473600 END)
                            FROM cookies WHERE host_key='douyin.com' OR host_key LIKE '%.douyin.com'"""
                        val summary = android.database.sqlite.SQLiteDatabase.openDatabase(file.path, null, flags).use { db ->
                            db.rawQuery(query, null).use { rows ->
                                check(rows.moveToFirst())
                                mapOf("cookies" to rows.getInt(0), "markers" to rows.getInt(1),
                                    "expiry" to if (rows.isNull(2)) null else rows.getLong(2))
                            }
                        }
                        runOnUiThread { result.success(summary) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("unavailable", "会话元数据暂不可读", null) }
                    }
                }.start()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "grupay/updates")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "build" -> result.success(packageManager.getPackageInfo(packageName, 0).versionCode)
                    "download" -> Thread {
                        try {
                            val url = URL(requireNotNull(call.argument<String>("url")))
                            val expected = requireNotNull(call.argument<String>("sha256"))
                            require(expected.matches(Regex("[0-9a-f]{64}")))
                            val directory = File(cacheDir, "updates").apply { mkdirs() }
                            val file = File.createTempFile("grupay-", ".apk", directory)
                            val connection = url.openConnection() as HttpsURLConnection
                            val digest = MessageDigest.getInstance("SHA-256")
                            try {
                                connection.instanceFollowRedirects = false
                                connection.connectTimeout = 15000
                                connection.readTimeout = 30000
                                check(connection.responseCode == 200)
                                DigestInputStream(connection.inputStream, digest).use { input ->
                                    file.outputStream().use { output -> input.copyTo(output) }
                                }
                                check(digest.digest().joinToString("") { "%02x".format(it) } == expected)
                                val archive = packageManager.getPackageArchiveInfo(file.path, 0)
                                check(archive?.packageName == packageName && archive.versionCode > packageManager.getPackageInfo(packageName, 0).versionCode)
                                val verified = File(directory, "$expected.apk")
                                check(file.renameTo(verified))
                                directory.listFiles()?.filter { it != verified }?.forEach { it.delete() }
                            } catch (e: Exception) {
                                file.delete()
                                throw e
                            } finally {
                                connection.disconnect()
                            }
                            runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("download", "下载或校验失败", null) }
                        }
                    }.start()
                    "install" -> try {
                        val hash = requireNotNull(call.argument<String>("sha256"))
                        require(hash.matches(Regex("[0-9a-f]{64}")))
                        val file = File(cacheDir, "updates/$hash.apk")
                        check(file.isFile)
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("installer", "无法打开系统安装器，请检查安装权限后重试", null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "grupay/screen_guard")
            .setMethodCallHandler { call, result ->
                if (call.method != "display") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (call.argument<Boolean>("awake") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                val attributes = window.attributes
                attributes.screenBrightness = if (call.argument<Boolean>("dimmed") == true) 0f else -1f
                window.attributes = attributes
                result.success(null)
            }
    }
}
