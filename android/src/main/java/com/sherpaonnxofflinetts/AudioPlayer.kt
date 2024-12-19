package com.sherpaonnxofflinetts

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.abs

class AudioPlayer(
    private val sampleRate: Int,
    private val channels: Int,
    private val delegate: AudioPlayerDelegate?
) {
    private var audioTrack: AudioTrack? = null
    private val audioQueue = LinkedBlockingQueue<FloatArray>()
    @Volatile private var isRunning = false

    private var playbackThread: Thread? = null

    // Instead of a ring buffer, we will accumulate samples to form 200 ms chunks.
    private val chunkDurationMs = 200L
    private val samplesPerChunk = ((sampleRate * channels * chunkDurationMs) / 1000).toInt()

    // A buffer to accumulate samples until we have at least one chunk
    private val accumulationBuffer = mutableListOf<Float>()

    // A queue to hold computed volumes for each chunk
    private val volumesQueue = LinkedBlockingQueue<Float>()

    // We'll update volume every 200 ms
    private val volumeUpdateIntervalMs: Long = 200
    private val scalingFactor = 0.42f

    private val mainHandler = Handler(Looper.getMainLooper())

    private val volumeUpdateRunnable = object : Runnable {
        override fun run() {
            if (!isRunning){
                return
            }

            // Attempt to retrieve a volume from the queue
            val volume = volumesQueue.poll()
            if (volume != null) {
                Log.d("kislaytest", "Volume Update: scaledVolume=$volume")
                delegate?.didUpdateVolume(volume)
            } else {
                delegate?.didUpdateVolume(0f)
            }

            if (isRunning) {
                mainHandler.postDelayed(this, volumeUpdateIntervalMs)
            }
        }
    }

    fun start() {
        val channelConfig = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO

        val desiredBufferDurationMs = 20
        val bufferSizeInSamples = (sampleRate * desiredBufferDurationMs) / 1000
        val bufferSizeInBytes = bufferSizeInSamples * 4 * channels
        val minBufferSizeInBytes = AudioTrack.getMinBufferSize(sampleRate, channelConfig, AudioFormat.ENCODING_PCM_FLOAT)

        if (minBufferSizeInBytes == AudioTrack.ERROR || minBufferSizeInBytes == AudioTrack.ERROR_BAD_VALUE) {
            throw IllegalStateException("Invalid buffer size")
        }

        val finalBufferSizeInBytes = maxOf(bufferSizeInBytes, minBufferSizeInBytes)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelConfig)
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .build()
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(finalBufferSizeInBytes)
            .build()

        audioTrack?.play()
        isRunning = true

        mainHandler.post(volumeUpdateRunnable) // Start the volume updater immediately

        playbackThread = Thread {
            Log.d("kislaytest", "Playback thread started.")
            while (isRunning) {
                try {
                    val samples = audioQueue.take()
                    synchronized(this) {
                        accumulationBuffer.addAll(samples.asList())
                        processAccumulatedSamples()
                    }
                    val result = audioTrack?.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING) ?: 0
                    if (result < 0) {
                        Log.e("kislaytest", "AudioTrack write error: $result")
                    } else {
                        Log.d("kislaytest", "Wrote ${samples.size} samples to AudioTrack")
                    }

                    // Accumulate samples for volume computation
                    

                } catch (e: InterruptedException) {
                    Log.d("kislaytest", "Playback thread interrupted")
                    break
                }
            }
            Log.d("kislaytest", "Playback thread exiting.")
        }
        playbackThread?.start()

        Log.d("kislaytest", "AudioPlayer started with sampleRate=$sampleRate, channels=$channels")
    }

    private fun processAccumulatedSamples() {
        // If we have enough samples for one or more 200ms chunks, compute volume for each chunk
        while (accumulationBuffer.size >= samplesPerChunk) {
            // Take first chunkSize samples
            val chunkSamples = accumulationBuffer.subList(0, samplesPerChunk).toFloatArray()
            accumulationBuffer.subList(0, samplesPerChunk).clear()

            val rawPeak = computePeak(chunkSamples)
            val volume = rawPeak * scalingFactor
            volumesQueue.offer(volume)

            Log.d("kislaytest", "Computed volume for a chunk: rawPeak=$rawPeak, scaledVolume=$volume")
        }
    }

    fun enqueueAudioData(samples: FloatArray, sr: Int) {
        if (sr != sampleRate) {
            throw IllegalArgumentException("Sample rate mismatch")
        }

        val minSample = samples.minOrNull() ?: 0f
        val maxSample = samples.maxOrNull() ?: 0f
        Log.d("kislaytest", "Enqueuing block: min=$minSample, max=$maxSample, size=${samples.size}")
        audioQueue.offer(samples)
    }

    private fun computePeak(data: FloatArray): Float {
        var maxVal = 0f
        for (sample in data) {
            val absVal = abs(sample)
            if (absVal > maxVal) {
                maxVal = absVal
            }
        }
        return maxVal
    }

    fun stopPlayer() {
        isRunning = false
        playbackThread?.interrupt()
        playbackThread?.join()

        mainHandler.removeCallbacks(volumeUpdateRunnable)

        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null

        synchronized(this) {
            accumulationBuffer.clear()
            volumesQueue.clear()
        }

        delegate?.didUpdateVolume(0f)
        Log.d("kislaytest", "AudioPlayer stopped and cleaned up")
    }
}
