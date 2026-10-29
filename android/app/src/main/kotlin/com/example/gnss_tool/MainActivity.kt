package com.example.gnss_tool

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.GnssStatus
import android.location.LocationListener
import android.location.LocationManager
import android.location.OnNmeaMessageListener
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

// 폰 내장 GNSS / 기압계 -> Dart (데이터 출처 "폰 GPS". 나중에 ESP32 BLE가 같은 자리에 들어감)
//  gnss_tool/gnss     : {type: nmea|sats|loc, ...}  오류 코드 PERMISSION_DENIED, GPS_OFF
//  gnss_tool/pressure : 1초 평균 기압(hPa)           오류 코드 NO_SENSOR
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val lm by lazy { getSystemService(Context.LOCATION_SERVICE) as LocationManager }
    private val sm by lazy { getSystemService(Context.SENSOR_SERVICE) as SensorManager }
    private var gnssSink: EventChannel.EventSink? = null
    private var pressureListener: SensorEventListener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

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

    companion object {
        private const val REQ_LOCATION = 1001
    }
}
