package com.eatova.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Keeps missing aggregates nullable and health values out of platform logs. */
class HealthConnectBridge(private val activity: Activity, engine: FlutterEngine) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "eatova/health_connect")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasStepsPermission" -> scope.launch {
                    try {
                        val client = HealthConnectClient.getOrCreate(activity)
                        val permission = HealthPermission.getReadPermission(StepsRecord::class)
                        result.success(client.permissionController.getGrantedPermissions().contains(permission))
                    } catch (e: CancellationException) {
                        result.error("cancelled", "Check cancelled", null)
                        throw e
                    } catch (_: Exception) {
                        result.error("permission_check_failed", "Steps access could not be checked", null)
                    }
                }
                "aggregateSteps" -> {
                    val start = call.argument<Number>("startTime")?.toLong()
                    val end = call.argument<Number>("endTime")?.toLong()
                    if (start == null || end == null || start < 0 || end <= start) {
                        result.error("invalid_interval", "Invalid interval", null)
                    } else {
                        scope.launch {
                            try {
                                val client = HealthConnectClient.getOrCreate(activity)
                                val permission = HealthPermission.getReadPermission(StepsRecord::class)
                                if (!client.permissionController.getGrantedPermissions().contains(permission)) {
                                    throw SecurityException()
                                }
                                val response = client.aggregate(
                                    AggregateRequest(
                                        metrics = setOf(StepsRecord.COUNT_TOTAL),
                                        timeRangeFilter = TimeRangeFilter.between(
                                            Instant.ofEpochMilli(start), Instant.ofEpochMilli(end)
                                        )
                                    )
                                )
                                // No origin/recording-method filter: Health Connect deduplicates.
                                result.success(response[StepsRecord.COUNT_TOTAL])
                            } catch (e: CancellationException) {
                                result.error("cancelled", "Read cancelled", null)
                                throw e
                            } catch (_: SecurityException) {
                                result.error("permission_denied", "Steps access unavailable", null)
                            } catch (_: Exception) {
                                result.error("read_failed", "Steps unavailable", null)
                            }
                        }
                    }
                }
                "openSettings" -> {
                    try {
                        activity.startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("settings_unavailable", "Health Connect settings unavailable", null)
                    }
                }
                "installOrUpdate" -> {
                    try {
                        try {
                            activity.startActivity(Intent(Intent.ACTION_VIEW,
                                Uri.parse("market://details?id=com.google.android.apps.healthdata"))
                                .setPackage("com.android.vending"))
                        } catch (_: ActivityNotFoundException) {
                            activity.startActivity(Intent(Intent.ACTION_VIEW,
                                Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata")))
                        }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("store_unavailable", "Health Connect installation unavailable", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}
