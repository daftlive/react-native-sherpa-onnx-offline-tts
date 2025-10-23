package com.sherpaonnxofflinetts

import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.k2fsa.sherpa.onnx.*
import android.content.res.AssetManager
import kotlin.concurrent.thread
import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import org.json.JSONObject

class ModelLoader(private val context: Context) {

    /**
     * Copies a file from the assets directory to the internal storage.
     *
     * @param assetPath The path to the asset in the assets directory.
     * @param outputFileName The name of the file in internal storage.
     * @return The absolute path to the copied file.
     * @throws IOException If an error occurs during file operations.
     */
    @Throws(IOException::class)
    fun loadModelFromAssets(assetPath: String, outputFileName: String): String {
        // Open the asset as an InputStream
        val assetManager = context.assets
        val inputStream = assetManager.open(assetPath)

        // Create a file in the app's internal storage
        val outFile = File(context.filesDir, outputFileName)
        FileOutputStream(outFile).use { output ->
            inputStream.copyTo(output)
        }

        // Close the InputStream
        inputStream.close()

        // Return the absolute path to the copied file
        return outFile.absolutePath
    }

    /**
     * Copies an entire directory from the assets to internal storage.
     *
     * @param assetDir The directory path in the assets.
     * @param outputDir The directory path in internal storage.
     * @throws IOException If an error occurs during file operations.
     */
    @Throws(IOException::class)
    fun copyAssetDirectory(assetDir: String, outputDir: File) {
        val assetManager = context.assets
        val files = assetManager.list(assetDir) ?: return

        if (!outputDir.exists()) {
            outputDir.mkdirs()
        }

        for (file in files) {
            val assetPath = if (assetDir.isEmpty()) file else "$assetDir/$file"
            val outFile = File(outputDir, file)

            if (assetManager.list(assetPath)?.isNotEmpty() == true) {
                // It's a directory
                copyAssetDirectory(assetPath, outFile)
            } else {
                // It's a file
                assetManager.open(assetPath).use { inputStream ->
                    FileOutputStream(outFile).use { outputStream ->
                        inputStream.copyTo(outputStream)
                    }
                }
            }
        }
    }
}


class TTSManagerModule(private val reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {

    private var tts: OfflineTts? = null
    private var realTimeAudioPlayer: AudioPlayer? = null
    private val modelLoader = ModelLoader(reactContext)

    override fun getName(): String {
        return "TTSManager"
    }

    // Initialize TTS and Audio Player
    @ReactMethod
    fun initializeTTS(sampleRate: Double, channels: Int, modelId: String) {
        // Setup Audio Player
        realTimeAudioPlayer = AudioPlayer(sampleRate.toInt(), channels, object : AudioPlayerDelegate {
            override fun didUpdateVolume(volume: Float) {
                sendVolumeUpdate(volume)
            }
        })

        // Determine model paths based on modelId
        
        // val modelDirAssetPath = "models"
        // val modelDirInternal = reactContext.filesDir
        // modelLoader.copyAssetDirectory(modelDirAssetPath, modelDirInternal)
        // val modelPath = File(modelDirInternal, if (modelId.lowercase() == "male") "en_US-ryan-medium.onnx" else "en_US-hfc_female-medium.onnx").absolutePath
        // val tokensPath = File(modelDirInternal, "tokens.txt").absolutePath
        // val dataDirPath = File(modelDirInternal, "espeak-ng-data").absolutePath // Directory copy handled above

        val jsonObject = JSONObject(modelId)
        val modelPath = jsonObject.getString("modelPath")
        val tokensPath = jsonObject.getString("tokensPath")
        val dataDirPath = jsonObject.getString("dataDirPath")

        // Build OfflineTtsConfig using the helper function
        val config = OfflineTtsConfig(
            model=OfflineTtsModelConfig(
              vits=OfflineTtsVitsModelConfig(
                model=modelPath,
                tokens=tokensPath,
                dataDir=dataDirPath,
              ),
              numThreads=1,
              debug=true,
            )
          )

        // Initialize sherpa-onnx offline TTS
        tts = OfflineTts(config=config)

        // Start the audio player
        realTimeAudioPlayer?.start()
    }

    // Generate audio and return as base64 string
    @ReactMethod
    fun generate(text: String, sid: Int, speed: Double, promise: Promise) {
        val trimmedText = text.trim()
        if (trimmedText.isEmpty()) {
            promise.reject("EMPTY_TEXT", "Input text is empty")
            return
        }

        try {
            // Split the text into manageable sentences
            val sentences = splitText(trimmedText, 15)
            val allSamples = mutableListOf<Float>()
            var sampleRate: Int = 0

            val startTime = System.currentTimeMillis()
            
            for (sentence in sentences) {
                val processedSentence = if (sentence.endsWith(".")) sentence else "$sentence."
                
                val audio = tts?.generate(processedSentence, sid, speed.toFloat())
                
                if (audio == null) {
                    promise.reject("TTS_ERROR", "TTS generation failed for sentence: $processedSentence")
                    return
                }
                
                if (sampleRate == 0) {
                    sampleRate = audio.sampleRate
                }
                
                // Append samples from this chunk
                allSamples.addAll(audio.samples.toList())
            }
            
            val endTime = System.currentTimeMillis()
            val generationTime = (endTime - startTime) / 1000.0
            println("Time taken for TTS generation: $generationTime seconds")

            // Convert float array to byte array
            val byteBuffer = java.nio.ByteBuffer.allocate(allSamples.size * 4)
            byteBuffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
            for (sample in allSamples) {
                byteBuffer.putFloat(sample)
            }
            val audioBytes = byteBuffer.array()
            
            // Convert to base64
            val base64String = android.util.Base64.encodeToString(audioBytes, android.util.Base64.NO_WRAP)

            val result = Arguments.createMap()
            result.putString("audioData", base64String)
            result.putInt("sampleRate", sampleRate)

            promise.resolve(result)
        } catch (e: Exception) {
            promise.reject("GENERATION_ERROR", "Error during audio generation: ${e.message}")
        }
    }

    private fun sendVolumeUpdate(volume: Float) {
        // Send volume update to JavaScript side
        val params = WritableNativeMap()
        params.putDouble("volume", volume.toDouble())
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("VolumeDidUpdate", params)
    }

    // Clean up resources
    @ReactMethod
    fun dispose() {
        // Release TTS resources
        tts?.dispose()
        tts = null

        // Stop and release audio player
        realTimeAudioPlayer?.stop()
        realTimeAudioPlayer = null
    }

    // Helper function to split text into smaller chunks
    private fun splitText(text: String, maxLength: Int): List<String> {
        val sentences = mutableListOf<String>()
        var currentSentence = StringBuilder()

        for (word in text.split(" ")) {
            if (currentSentence.length + word.length + 1 > maxLength) {
                sentences.add(currentSentence.toString())
                currentSentence = StringBuilder(word)
            } else {
                if (currentSentence.isNotEmpty()) {
                    currentSentence.append(" ")
                }
                currentSentence.append(word)
            }
        }

        // Add the last sentence if not empty
        if (currentSentence.isNotEmpty()) {
            sentences.add(currentSentence.toString())
        }

        return sentences
    }
}
