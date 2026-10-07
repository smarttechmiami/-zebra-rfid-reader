package com.smarttechmiami.zebra_rfid_reader

import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import com.zebra.rfid.api3.ENUM_TRANSPORT
import com.zebra.rfid.api3.HANDHELD_TRIGGER_EVENT_TYPE
import com.zebra.rfid.api3.READER_EVENT_TYPE
import com.zebra.rfid.api3.RFIDReader
import com.zebra.rfid.api3.RfidEventsListener
import com.zebra.rfid.api3.RfidReadEvents
import com.zebra.rfid.api3.RfidStatusEvents
import com.zebra.rfid.api3.Readers
import com.zebra.rfid.api3.ReaderDevice
import com.zebra.rfid.api3.START_TRIGGER_TYPE
import com.zebra.rfid.api3.STOP_TRIGGER_TYPE
import com.zebra.rfid.api3.TagData
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** Flutter plugin wrapping Zebra's RFID API3 SDK for continuous inventory reads. */
class ZebraRfidReaderPlugin : FlutterPlugin, MethodCallHandler {
  private lateinit var methodChannel: MethodChannel
  private lateinit var tagEventChannel: EventChannel
  private lateinit var connectionEventChannel: EventChannel
  private lateinit var triggerEventChannel: EventChannel

  private var readers: Readers? = null
  private var reader: RFIDReader? = null

  private var tagSink: EventChannel.EventSink? = null
  private var connectionSink: EventChannel.EventSink? = null
  private var triggerSink: EventChannel.EventSink? = null

  private val mainHandler = Handler(Looper.getMainLooper())
  private val seenTagIds = mutableSetOf<String>()

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel = MethodChannel(binding.binaryMessenger, "zebra_rfid_reader/methods")
    methodChannel.setMethodCallHandler(this)

    tagEventChannel = EventChannel(binding.binaryMessenger, "zebra_rfid_reader/tag_events")
    tagEventChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
          tagSink = events
        }

        override fun onCancel(arguments: Any?) {
          tagSink = null
        }
      },
    )

    connectionEventChannel =
      EventChannel(binding.binaryMessenger, "zebra_rfid_reader/connection_events")
    connectionEventChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
          connectionSink = events
        }

        override fun onCancel(arguments: Any?) {
          connectionSink = null
        }
      },
    )

    triggerEventChannel = EventChannel(binding.binaryMessenger, "zebra_rfid_reader/trigger_events")
    triggerEventChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
          triggerSink = events
        }

        override fun onCancel(arguments: Any?) {
          triggerSink = null
        }
      },
    )
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    methodChannel.setMethodCallHandler(null)
    tagEventChannel.setStreamHandler(null)
    connectionEventChannel.setStreamHandler(null)
    triggerEventChannel.setStreamHandler(null)
    disconnect()
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "availableReaders" -> availableReaders(result)
      "connect" -> connect(call.argument<String>("name"), result)
      "disconnect" -> {
        disconnect()
        result.success(null)
      }
      "startInventory" -> startInventory(result)
      "stopInventory" -> stopInventory(result)
      "readAllTagsOnce" -> readAllTagsOnce(call.argument<Int>("timeoutMs") ?: 3000, result)
      "sendZplToPrinter" -> sendZplToPrinter(
        call.argument<String>("ip") ?: "192.168.0.252",
        call.argument<Int>("port") ?: 9100,
        call.argument<String>("zpl") ?: "",
        result
      )
      "testPrinterConnection" -> testPrinterConnection(
        call.argument<String>("ip") ?: "192.168.0.252",
        call.argument<Int>("port") ?: 9100,
        result
      )
      else -> result.notImplemented()
    }
  }

  // ---------------------------------------------------------------------
  // Discovery / connection
  // ---------------------------------------------------------------------

  private fun ensureReaders(): Readers {
    var r = readers
    if (r == null) {
      r = Readers(null, ENUM_TRANSPORT.SERVICE_BLUETOOTH)
      readers = r
    }
    return r
  }

  private fun availableReaders(result: Result) {
    try {
      val found = mutableListOf<ReaderDevice>()
      for (transport in
        listOf(
          ENUM_TRANSPORT.SERVICE_BLUETOOTH,
          ENUM_TRANSPORT.SERVICE_SERIAL,
          ENUM_TRANSPORT.SERVICE_USB,
        )) {
        try {
          val r = Readers(null, transport)
          val available = r.GetAvailableRFIDReaderList()
          if (available != null) found.addAll(available)
        } catch (_: Exception) {
          // This transport isn't available on this device — skip it.
        }
      }
      val seenNames = mutableSetOf<String>()
      val payload =
        found
          .filter { seenNames.add(it.name) }
          .map { mapOf("name" to it.name) }
      result.success(payload)
    } catch (e: Exception) {
      result.error("AVAILABLE_READERS_FAILED", e.message, null)
    }
  }

  private fun connect(name: String?, result: Result) {
    if (name == null) {
      result.error("INVALID_ARGUMENT", "name is required", null)
      return
    }
    try {
      emitConnectionState("connecting")
      val readerList = ensureReaders().GetAvailableRFIDReaderList()
      val device =
        readerList?.firstOrNull { it.name == name }
          ?: throw IllegalStateException("Reader \"$name\" not found")
      val r = device.rfidReader
      r.connect()
      configureReader(r)
      reader = r
      emitConnectionState("connected")
      result.success(null)
    } catch (e: Exception) {
      emitConnectionState("disconnected")
      result.error("CONNECT_FAILED", e.message, null)
    }
  }

  private fun configureReader(r: RFIDReader) {
    r.Events.setHandheldEvent(true)
    r.Events.setTagReadEvent(true)
    r.Events.setAttachTagDataWithReadEvent(false)
    r.Config.setStartTrigger(START_TRIGGER_TYPE.START_TRIGGER_TYPE_IMMEDIATE)
    r.Config.setStopTrigger(STOP_TRIGGER_TYPE.STOP_TRIGGER_TYPE_IMMEDIATE)
    r.Events.addEventsListener(
      object : RfidEventsListener {
        override fun eventReadNotify(e: RfidReadEvents) {
          onTagsRead()
        }

        override fun eventStatusNotify(e: RfidStatusEvents) {
          val status = e.StatusEventData
          if (status.getStatusEventType() != READER_EVENT_TYPE.HANDHELD_TRIGGER_EVENT) return
          when (status.HandheldTriggerEventData.getHandheldEvent()) {
            HANDHELD_TRIGGER_EVENT_TYPE.HANDHELD_TRIGGER_PRESSED -> {
              seenTagIds.clear()
              emitTriggerState("pressed")
              runCatching { r.Actions.Inventory.perform() }
            }
            HANDHELD_TRIGGER_EVENT_TYPE.HANDHELD_TRIGGER_RELEASED -> {
              emitTriggerState("released")
              runCatching { r.Actions.Inventory.stop() }
            }
            else -> Unit
          }
        }
      },
    )
  }

  private fun disconnect() {
    try {
      reader?.Actions?.Inventory?.stop()
    } catch (_: Exception) {
    }
    try {
      reader?.disconnect()
    } catch (_: Exception) {
    }
    reader = null
    emitConnectionState("disconnected")
  }

  // ---------------------------------------------------------------------
  // Inventory
  // ---------------------------------------------------------------------

  private fun startInventory(result: Result) {
    val r = reader
    if (r == null) {
      result.error("NOT_CONNECTED", "No reader connected", null)
      return
    }
    try {
      seenTagIds.clear()
      r.Actions.Inventory.perform()
      result.success(null)
    } catch (e: Exception) {
      result.error("START_INVENTORY_FAILED", e.message, null)
    }
  }

  private fun stopInventory(result: Result) {
    val r = reader
    if (r == null) {
      result.error("NOT_CONNECTED", "No reader connected", null)
      return
    }
    try {
      r.Actions.Inventory.stop()
      result.success(null)
    } catch (e: Exception) {
      result.error("STOP_INVENTORY_FAILED", e.message, null)
    }
  }

  private fun readAllTagsOnce(timeoutMs: Int, result: Result) {
    val r = reader
    if (r == null) {
      result.error("NOT_CONNECTED", "No reader connected", null)
      return
    }
    try {
      seenTagIds.clear()
      val collected = mutableMapOf<String, Map<String, Any>>()
      r.Actions.Inventory.perform()
      mainHandler.postDelayed(
        {
          try {
            r.Actions.Inventory.stop()
          } catch (_: Exception) {
          }
          drainReadTags(r)?.forEach { tag ->
            collected[tag["tagId"] as String] = tag
          }
          result.success(collected.values.toList())
        },
        timeoutMs.toLong(),
      )
    } catch (e: Exception) {
      result.error("READ_ONCE_FAILED", e.message, null)
    }
  }

  private fun onTagsRead() {
    val r = reader ?: return
    val tags = drainReadTags(r) ?: return
    val sink = tagSink ?: return
    mainHandler.post {
      tags.forEach { sink.success(it) }
    }
  }

  private fun drainReadTags(r: RFIDReader): List<Map<String, Any>>? {
    val tags: Array<TagData>? = r.Actions.getReadTags(100)
    if (tags == null) return null
    return tags
      .filter { seenTagIds.add(it.tagID) }
      .map { tag ->
        mapOf(
          "tagId" to tag.tagID,
          "rssi" to tag.peakRSSI,
          "antennaId" to tag.antennaID,
        )
      }
  }

  // ---------------------------------------------------------------------
  // Network Printer Support
  // ---------------------------------------------------------------------

  private fun sendZplToPrinter(ip: String, port: Int, zpl: String, result: Result) {
    Thread {
      try {
        val socket = java.net.Socket(ip, port)
        socket.soTimeout = 5000
        val os = socket.getOutputStream()
        os.write(zpl.toByteArray(Charsets.UTF_8))
        os.flush()
        os.close()
        socket.close()
        mainHandler.post { result.success(true) }
      } catch (e: Exception) {
        mainHandler.post { result.error("PRINTER_ERROR", e.message, null) }
      }
    }.start()
  }

  private fun testPrinterConnection(ip: String, port: Int, result: Result) {
    Thread {
      try {
        val socket = java.net.Socket()
        socket.connect(java.net.InetSocketAddress(ip, port), 3000)
        socket.close()
        mainHandler.post { result.success(true) }
      } catch (e: Exception) {
        mainHandler.post { result.success(false) }
      }
    }.start()
  }

  // ---------------------------------------------------------------------
  // Event emission helpers
  // ---------------------------------------------------------------------

  private fun emitConnectionState(state: String) {
    mainHandler.post { connectionSink?.success(state) }
  }

  private fun emitTriggerState(state: String) {
    mainHandler.post { triggerSink?.success(state) }
  }
}
