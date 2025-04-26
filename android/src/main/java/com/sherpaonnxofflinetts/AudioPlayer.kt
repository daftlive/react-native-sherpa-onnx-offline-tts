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
    @Volatile private var sentCompletion = false          // ← NEW

    private var playbackThread: Thread? = null

    private val chunkDurationMs = 200L
    private val samplesPerChunk = ((sampleRate * channels * chunkDurationMs) / 1000).toInt()
    private val accumulationBuffer = mutableListOf<Float>()
    private val volumesQueue = LinkedBlockingQueue<Float>()

    private val volumeUpdateIntervalMs: Long = 200
    private val scalingFactor = 0.42f

    private val mainHandler = Handler(Looper.getMainLooper())

    private val volumeUpdateRunnable = object : Runnable {
        override fun run() {
            if (!isRunning) return

            val volume = volumesQueue.poll()
            if (volume != null) {
                delegate?.didUpdateVolume(volume)
            } else if (!sentCompletion) {                 // don't spam 0 after -1
                delegate?.didUpdateVolume(0f)
            }

            if (isRunning) {
                mainHandler.postDelayed(this, volumeUpdateIntervalMs)
            }
        }
    }

    fun start() {
        val channelConfig = if (channels == 1)
            AudioFormat.CHANNEL_OUT_MONO
        else
            AudioFormat.CHANNEL_OUT_STEREO

        val desiredBufferDurationMs = 20
        val bufferSizeInSamples = (sampleRate * desiredBufferDurationMs) / 1000
        val bufferSizeInBytes = bufferSizeInSamples * 4 * channels
        val minBufferSizeInBytes = AudioTrack.getMinBufferSize(
            sampleRate, channelConfig, AudioFormat.ENCODING_PCM_FLOAT
        )

        if (minBufferSizeInBytes == AudioTrack.ERROR || minBufferSizeInBytes == AudioTrack.ERROR_BAD_VALUE) {
            throw IllegalStateException("Invalid buffer size")
        }

        val finalBufferSizeInBytes = maxOf(bufferSizeInBytes, minBufferSizeInBytes)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC) // ← CHANGED
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

        mainHandler.post(volumeUpdateRunnable)

        playbackThread = Thread {
            Log.d("kislaytest", "Playback thread started.")
            while (isRunning) {
                try {
                    val samples = audioQueue.take()
                    synchronized(this) {
                        accumulationBuffer.addAll(samples.asList())
                        processAccumulatedSamples()
                    }
                    audioTrack?.write(samples, 0, samples.size, AudioTrack.WRITE_BLOCKING)
                    maybeSendCompletion()                   // ← NEW
                } catch (e: InterruptedException) {
                    break
                }
            }
        }
        playbackThread?.start()
    }

    private fun processAccumulatedSamples() {
        while (accumulationBuffer.size >= samplesPerChunk) {
            val chunkSamples = accumulationBuffer.subList(0, samplesPerChunk).toFloatArray()
            accumulationBuffer.subList(0, samplesPerChunk).clear()

            val rawPeak = computePeak(chunkSamples)
            val volume = rawPeak * scalingFactor
            volumesQueue.offer(volume)
        }
    }

    fun enqueueAudioData(samples: FloatArray, sr: Int) {
        if (sr != sampleRate) throw IllegalArgumentException("Sample rate mismatch")
        sentCompletion = false                              // ← reset
        audioQueue.offer(samples)
    }

    private fun computePeak(data: FloatArray): Float {
        var maxVal = 0f
        for (sample in data) {
            val absVal = abs(sample)
            if (absVal > maxVal) maxVal = absVal
        }
        return maxVal
    }

    // Completion helper
    private fun maybeSendCompletion() {
        if (!sentCompletion && audioQueue.isEmpty() && accumulationBuffer.isEmpty()) {
            sentCompletion = true
            mainHandler.post { delegate?.didUpdateVolume(-1f) }
        }
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

        mainHandler.post { delegate?.didUpdateVolume(-1f) } // ← now sends -1
    }
}
