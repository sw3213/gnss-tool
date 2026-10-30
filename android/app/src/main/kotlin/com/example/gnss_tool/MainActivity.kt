package com.example.gnss_tool

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.GnssStatus
import android.location.LocationListener
import android.location.LocationManager
import android.location.OnNmeaMessageListener
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

// 폰 내장 GNSS / 기압계 -> Dart (데이터 출처 "폰 GPS". 나중에 ESP32 BLE가 같은 자리에 들어감)
//  gnss_tool/gnss     : {type: nmea|sats|loc, ...}  오류 코드 PERMISSION_DENIED, GPS_OFF
//  gnss_tool/pressure : 1초 평균 기압(hPa)           오류 코드 NO_SENSOR
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val lm by lazy { getSystemService(Context.LOCATION_SERVICE) as LocationManager }
    private val sm by lazy { getSystemService(Context.SENSOR_SERVICE) as SensorManager }
    private var gnssSink: EventChannel.EventSink? = null
    private var pressureListener: SensorEventListener? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 자바 쪽 예외로 죽으면 원인을 파일에 남김 -> 다음 실행 때 앱 화면에 보여 줌
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            runCatching { crashFile().writeText(e.stackTraceToString().take(6000)) }
            previous?.uncaughtException(thread, e)
        }
        super.onCreate(savedInstanceState)
    }

    private fun crashFile() = File(filesDir, "last_crash.txt")

    /** 직전 실행이 크래시·ANR로 끝났는지 (업데이트 설치, 사용자가 닫음 등 정상 종료는 false) */
    private val lastExitWasCrash: Boolean by lazy {
        if (crashFile().exists()) return@lazy true
        if (Build.VERSION.SDK_INT < 30) return@lazy false
        val info = getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull()
        info?.reason in setOf(
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
        )
    }

    /** 지난 실행이 비정상 종료였다면 그 이유(한 번만 반환), 아니면 null */
    private fun lastCrash(): String? {
        val parts = mutableListOf<String>()
        val f = crashFile()
        if (f.exists()) {
            parts += f.readText()
            f.delete()
        }
        // 네이티브(지도 엔진 C++) 크래시는 위 처리기에 안 잡힘 -> 안드로이드 종료 기록(11+)에서 읽음
        if (Build.VERSION.SDK_INT >= 30) {
            val prefs = getSharedPreferences("diag", MODE_PRIVATE)
            val seen = prefs.getLong("exit_ts", 0)
            val am = getSystemService(ActivityManager::class.java)
            val info = am.getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull()
            if (info != null && info.timestamp > seen) {
                prefs.edit().putLong("exit_ts", info.timestamp).apply()
                val reason = when (info.reason) {
                    ApplicationExitInfo.REASON_CRASH -> "자바 예외"
                    ApplicationExitInfo.REASON_CRASH_NATIVE -> "네이티브 크래시"
                    ApplicationExitInfo.REASON_ANR -> "응답 없음(ANR)"
                    ApplicationExitInfo.REASON_LOW_MEMORY -> "메모리 부족"
                    else -> null
                }
                if (reason != null) {
                    parts += "종료 이유: $reason (${info.description ?: ""})"
                    if (Build.VERSION.SDK_INT >= 31 && info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                        // 톰스톤(바이너리)에서 읽을 수 있는 문자열만 추림: 중단 메시지, 스택의 라이브러리·함수 이름
                        val bytes = runCatching { info.traceInputStream?.use { it.readBytes() } }.getOrNull()
                        if (bytes != null) {
                            val text = Regex("[\\x20-\\x7e]{6,}").findAll(String(bytes, Charsets.ISO_8859_1))
                                .map { it.value }.distinct().take(80).joinToString("\n")
                            parts += text.take(5000)
                        }
                    }
                }
            }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString("\n\n")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        lastExitWasCrash // lastCrash()가 크래시 파일을 지우기 전에 먼저 판정해 둠
        MethodChannel(messenger, "gnss_tool/diag").setMethodCallHandler { call, result ->
            when (call.method) {
                "lastCrash" -> result.success(runCatching { lastCrash() }.getOrNull())
                "lastExitWasCrash" -> result.success(lastExitWasCrash)
                // 배터리 잔량·온도 (조언: 배터리 부족, 폰 과열). 권한 없이 시스템 방송의 마지막 값을 읽음
                "battery" -> {
                    val i = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    if (i == null) result.success(null) else {
                        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                        result.success(mapOf(
                            "percent" to if (level < 0) null else level * 100.0 / scale,
                            "tempC" to i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1000) / 10.0,
                            "charging" to (i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0),
                        ))
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 지도 다운로드는 안드로이드 다운로드 관리자에 맡김: 앱을 닫아도 계속 받고, 끊기면 알아서 이어받고,
        // 알림창에 진행률 표시. 저장 위치는 앱 전용 외부 저장소(권한 불필요, 앱 삭제 시 함께 삭제)
        MethodChannel(messenger, "gnss_tool/download").setMethodCallHandler { call, result ->
            val dm = getSystemService(DownloadManager::class.java)
            when (call.method) {
                "start" -> {
                    val wifiOnly = call.argument<Boolean>("wifiOnly") ?: true
                    val req = DownloadManager.Request(Uri.parse(call.argument<String>("url")))
                        .setTitle(call.argument<String>("title"))
                        .setDescription("GNSS Tool 오프라인 지도")
                        .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                        .setDestinationInExternalFilesDir(this, "maps", call.argument<String>("file"))
                        .setAllowedOverMetered(!wifiOnly) // false = 와이파이 같은 무제한 네트워크에서만
                        .setAllowedOverRoaming(false)
                    result.success(dm.enqueue(req))
                }
                "query" -> {
                    val id = call.argument<Number>("id")!!.toLong()
                    dm.query(DownloadManager.Query().setFilterById(id)).use { c ->
                        if (!c.moveToFirst()) {
                            result.success(null)
                        } else {
                            fun col(name: String) = c.getColumnIndexOrThrow(name)
                            result.success(
                                mapOf(
                                    "status" to c.getInt(col(DownloadManager.COLUMN_STATUS)),
                                    "reason" to c.getInt(col(DownloadManager.COLUMN_REASON)),
                                    "done" to c.getLong(col(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                                    "total" to c.getLong(col(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                                    "uri" to c.getString(col(DownloadManager.COLUMN_LOCAL_URI)),
                                )
                            )
                        }
                    }
                }
                "remove" -> result.success(dm.remove(call.argument<Number>("id")!!.toLong()))
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "gnss_tool/gnss").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                gnssSink = events
                if (hasFineLocation()) {
                    startGnss()
                } else {
                    // Android 12+는 FINE만 요청하면 무시되므로 COARSE도 함께 요청
                    requestPermissions(
                        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                        REQ_LOCATION,
                    )
                }
            }

            override fun onCancel(arguments: Any?) {
                stopGnss()
                gnssSink = null
            }
        })

        EventChannel(messenger, "gnss_tool/pressure").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) = startPressure(events)
            override fun onCancel(arguments: Any?) = stopPressure()
        })

        EventChannel(messenger, "gnss_tool/heading").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) = startHeading(events)
            override fun onCancel(arguments: Any?) = stopHeading()
        })
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_LOCATION) return
        // "대략적 위치"만 허용하면 위성 정보가 안 나오므로 FINE 여부로 판단
        if (hasFineLocation()) startGnss()
        else gnssSink?.error("PERMISSION_DENIED", "정확한 위치 권한이 필요함", null)
    }

    private fun hasFineLocation() =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    // ---------------- GNSS ----------------

    private val locListener = LocationListener { loc ->
        gnssSink?.success(
            mapOf(
                "type" to "loc",
                "hAcc" to (if (loc.hasAccuracy()) loc.accuracy.toDouble() else null),
                "vAcc" to (if (Build.VERSION.SDK_INT >= 26 && loc.hasVerticalAccuracy()) loc.verticalAccuracyMeters.toDouble() else null),
            )
        )
    }

    private val nmeaListener = OnNmeaMessageListener { message, _ ->
        gnssSink?.success(mapOf("type" to "nmea", "line" to message))
    }

    private val statusCallback = object : GnssStatus.Callback() {
        override fun onSatelliteStatusChanged(status: GnssStatus) {
            // 위성(신호)마다 [constellation, svid, az, el, cn0, usedInFix, carrierHz]. 듀얼밴드면 같은 위성이 두 번 옴
            val sats = ArrayList<List<Any>>(status.satelliteCount)
            for (i in 0 until status.satelliteCount) {
                val hz = if (Build.VERSION.SDK_INT >= 26 && status.hasCarrierFrequencyHz(i)) status.getCarrierFrequencyHz(i).toDouble() else 0.0
                sats.add(
                    listOf(
                        status.getConstellationType(i),
                        status.getSvid(i),
                        status.getAzimuthDegrees(i).toDouble(),
                        status.getElevationDegrees(i).toDouble(),
                        status.getCn0DbHz(i).toDouble(),
                        status.usedInFix(i),
                        hz,
                    )
                )
            }
            gnssSink?.success(mapOf("type" to "sats", "sats" to sats))
        }
    }

    @SuppressLint("MissingPermission") // hasFineLocation() 확인 후에만 호출
    private fun startGnss() {
        if (!lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
            gnssSink?.error("GPS_OFF", "위치(GPS)가 꺼져 있음", null)
            return
        }
        lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, locListener, Looper.getMainLooper())
        lm.addNmeaListener(nmeaListener, main)
        lm.registerGnssStatusCallback(statusCallback, main)
    }

    private fun stopGnss() {
        lm.removeUpdates(locListener)
        lm.removeNmeaListener(nmeaListener)
        lm.unregisterGnssStatusCallback(statusCallback)
    }

    // ---------------- 기압계 ----------------

    private fun startPressure(events: EventChannel.EventSink) {
        val sensor = sm.getDefaultSensor(Sensor.TYPE_PRESSURE)
        if (sensor == null) {
            events.error("NO_SENSOR", "기압 센서 없음", null)
            return
        }
        val listener = object : SensorEventListener {
            var sum = 0.0
            var n = 0
            var last = System.currentTimeMillis()

            override fun onSensorChanged(e: SensorEvent) {
                sum += e.values[0]
                n++
                val now = System.currentTimeMillis()
                if (now - last >= 1000) { // 센서는 수~수십 Hz -> 1초 평균만 전달
                    events.success(sum / n)
                    sum = 0.0
                    n = 0
                    last = now
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        pressureListener = listener
        sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL, main)
    }

    private fun stopPressure() {
        pressureListener?.let { sm.unregisterListener(it) }
        pressureListener = null
    }

    // ---------------- 나침반 ----------------
    // 회전 벡터 센서(가속도+자기+자이로 융합)로 폰 윗변이 가리키는 방위. 자북 기준이라
    // 마지막 위치의 자기 편각(한국 약 -8~-9°)을 더해 진북(지도 북쪽) 기준으로 보냄

    private var headingListener: SensorEventListener? = null

    @SuppressLint("MissingPermission")
    private fun declination(): Float {
        if (!hasFineLocation()) return 0f
        val loc = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) ?: return 0f
        return android.hardware.GeomagneticField(
            loc.latitude.toFloat(), loc.longitude.toFloat(), loc.altitude.toFloat(), System.currentTimeMillis()
        ).declination
    }

    private fun startHeading(events: EventChannel.EventSink) {
        val sensor = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (sensor == null) {
            events.error("NO_SENSOR", "방향 센서 없음", null)
            return
        }
        val listener = object : SensorEventListener {
            val rot = FloatArray(9)
            val orient = FloatArray(3)
            var decl = declination()
            var declAt = System.currentTimeMillis()
            var lastSent = 0L
            var lastDeg = -1000.0

            override fun onSensorChanged(e: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rot, e.values)
                SensorManager.getOrientation(rot, orient)
                val now = System.currentTimeMillis()
                if (now - declAt > 60_000) {
                    decl = declination()
                    declAt = now
                }
                val deg = ((Math.toDegrees(orient[0].toDouble()) + decl + 360) % 360)
                var diff = Math.abs(deg - lastDeg)
                if (diff > 180) diff = 360 - diff
                // 초당 최대 10번, 1° 이상 바뀔 때만 (화면 갱신·배터리 절약)
                if (now - lastSent >= 100 && diff >= 1) {
                    events.success(deg)
                    lastSent = now
                    lastDeg = deg
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        headingListener = listener
        sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI, main)
    }

    private fun stopHeading() {
        headingListener?.let { sm.unregisterListener(it) }
        headingListener = null
    }

    companion object {
        private const val REQ_LOCATION = 1001
    }
}
