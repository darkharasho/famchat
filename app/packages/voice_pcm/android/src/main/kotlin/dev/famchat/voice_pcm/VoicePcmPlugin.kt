// Decodes a voice clip to 16 kHz mono Float32 with MediaExtractor and MediaCodec, resampling as it
// goes (a 44.1 kHz clip at its own rate would need almost three times the memory).
package dev.famchat.voice_pcm

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder
import java.util.concurrent.Executors

class VoicePcmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "voice_pcm").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (call.method != "decode" || path == null) {
            result.notImplemented()
            return
        }
        worker.execute {
            try {
                val (samples, rate) = decode(path)
                main.post { result.success(mapOf("samples" to samples, "sampleRate" to rate)) }
            } catch (e: Throwable) {
                // Throwable: a clip too big for memory fails the transcript, not the app.
                main.post { result.error("decode_failed", e.toString(), null) }
            }
        }
    }

    private fun decode(path: String): Pair<FloatArray, Int> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IllegalArgumentException("no audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            var out = FloatArray((durationUs * OUT_RATE / 1_000_000L).toInt().coerceIn(0, 1 shl 26) + 4096)
            var n = 0
            // Linear resampling, streamed: [pos] is the next output sample's time in input samples.
            var pos = 0.0
            var k = -1L
            var prev = 0f
            fun push(cur: Float) {
                k++
                while (pos <= k) {
                    val v = if (k == 0L) cur else prev + (cur - prev) * (pos - (k - 1)).toFloat()
                    if (n == out.size) out = out.copyOf(out.size + out.size / 2 + 4096)
                    out[n++] = v
                    pos += rate.toDouble() / OUT_RATE
                }
                prev = cur
            }
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val size = extractor.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val ordered = buf.order(ByteOrder.nativeOrder())
                    if (isFloat) {
                        val floats = ordered.asFloatBuffer()
                        for (f in 0 until floats.remaining() / channels) {
                            var sum = 0f
                            for (c in 0 until channels) sum += floats.get()
                            push(sum / channels)
                        }
                    } else {
                        val shorts = ordered.asShortBuffer()
                        for (f in 0 until shorts.remaining() / channels) {
                            var sum = 0f
                            for (c in 0 until channels) sum += shorts.get() / 32768f
                            push(sum / channels)
                        }
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            return Pair(out.copyOf(n), OUT_RATE)
        } finally {
            codec?.let {
                try { it.stop() } catch (_: Exception) {}
                it.release()
            }
            extractor.release()
        }
    }

    private companion object {
        const val OUT_RATE = 16000
    }
}
