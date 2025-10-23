// TTSManager.swift

import Foundation
import AVFoundation
import React

// Define a protocol for volume updates
protocol AudioPlayerDelegate: AnyObject {
    func didUpdateVolume(_ volume: Float)
}

@objc(TTSManager)
class TTSManager: RCTEventEmitter, AudioPlayerDelegate {
    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var realTimeAudioPlayer: AudioPlayer?
    private var sampleRate: Double = 22050 // Store sample rate
    
    override init() {
        super.init()
        // Optionally, initialize AudioPlayer here if needed
    }
    
    // Required for RCTEventEmitter
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    // Specify the events that can be emitted
    override func supportedEvents() -> [String]! {
        return ["VolumeUpdate", "AudioChunkGenerated"]
    }
    
    // Initialize TTS and Audio Player
    @objc(initializeTTS:channels:modelId:)
    func initializeTTS(_ sampleRate: Double, channels: Int, modelId: String) {
        self.sampleRate = sampleRate // Store for later use
        self.realTimeAudioPlayer = AudioPlayer(sampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        self.realTimeAudioPlayer?.delegate = self // Set delegate to receive volume updates
        self.tts = createOfflineTts(modelId: modelId)
    }

    // Generate audio and play in real-time
    @objc(generateAndPlay:sid:speed:resolver:rejecter:)
    func generateAndPlay(_ text: String, sid: Int, speed: Double, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedText.isEmpty else {
            rejecter("EMPTY_TEXT", "Input text is empty", nil)
            return
        }
        
        // Split the text into manageable sentences
        let sentences = splitText(trimmedText, maxWords: 15)
        
        for sentence in sentences {
            let processedSentence = sentence.hasSuffix(".") ? sentence : "\(sentence)."
            generateAudio(for: processedSentence, sid: sid, speed: speed)
        }
        
        resolver("Audio generated and played successfully")
    }

    // Generate audio without playing - emit chunks progressively
    @objc(generate:sid:speed:resolver:rejecter:)
    func generate(_ text: String, sid: Int, speed: Double, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedText.isEmpty else {
            rejecter("EMPTY_TEXT", "Input text is empty", nil)
            return
        }
        
        let sentences = splitText(trimmedText, maxWords: 15)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            for (index, sentence) in sentences.enumerated() {
                let processedSentence = sentence.hasSuffix(".") ? sentence : "\(sentence)."
                
                guard let audio = self.tts?.generate(text: processedSentence, sid: sid, speed: Float(speed)) else {
                    DispatchQueue.main.async {
                        rejecter("GENERATION_ERROR", "Failed to generate audio for sentence: \(processedSentence)", nil)
                    }
                    return
                }
                
                var samples = audio.samples
                var sampleCount = samples.count
                
                // *** TRIM ULTRA-AGRESIVO ***
                let silenceThreshold: Float = 0.002 // Threshold muy bajo
                
                // Primera pasada: encontrar el último sample significativo
                var foundSignificantAudio = false
                for i in stride(from: sampleCount - 1, through: 0, by: -1) {
                    if abs(samples[i]) > silenceThreshold {
                        sampleCount = i + 1
                        foundSignificantAudio = true
                        break
                    }
                }
                
                print("First pass trim: \(samples.count) → \(sampleCount) samples")
                
                // Segunda pasada ULTRA-AGRESIVA para el último chunk
                if index == sentences.count - 1 && foundSignificantAudio {
                    // Buscar hacia atrás con threshold más alto
                    let aggressiveThreshold: Float = 0.008
                    var aggressiveTrimPoint = sampleCount
                    
                    for i in stride(from: sampleCount - 1, through: max(0, sampleCount - 500), by: -1) {
                        if abs(samples[i]) > aggressiveThreshold {
                            aggressiveTrimPoint = i + 1
                            break
                        }
                    }
                    
                    sampleCount = aggressiveTrimPoint
                    print("Aggressive trim for last chunk: → \(sampleCount) samples")
                    
                    // Buffer ultra-mínimo (2ms)
                    let bufferSamples = Int(self.sampleRate * 0.002)
                    sampleCount = min(sampleCount + bufferSamples, samples.count)
                } else {
                    // Chunks intermedios: buffer de 8ms
                    let bufferSamples = Int(self.sampleRate * 0.008)
                    sampleCount = min(sampleCount + bufferSamples, samples.count)
                }
                
                print("Final sample count for chunk \(index + 1): \(sampleCount)")
                
                // LOG: Mostrar los últimos 20 samples ANTES del trim
                let last20Before = samples.suffix(20).map { String(format: "%.6f", $0) }.joined(separator: ", ")
                print("Last 20 samples BEFORE trim: [\(last20Before)]")
                
                // Aplicar el trim
                samples = Array(samples.prefix(sampleCount))
                
                // LOG: Mostrar los últimos 20 samples DESPUÉS del trim
                let last20After = samples.suffix(20).map { String(format: "%.6f", $0) }.joined(separator: ", ")
                print("Last 20 samples AFTER trim: [\(last20After)]")
                
                // Convert to Data
                let data = samples.withUnsafeBytes { bufferPointer in
                    Data(bufferPointer)
                }
                let base64Audio = data.base64EncodedString()
                
                // Emit chunk
                DispatchQueue.main.async {
                    self.sendEvent(withName: "AudioChunkGenerated", body: [
                        "chunk": base64Audio,
                        "index": index,
                        "total": sentences.count,
                        "sampleRate": Int(self.sampleRate)
                    ])
                }
            }
            
            DispatchQueue.main.async {
                resolver(["success": true, "totalChunks": sentences.count])
            }
        }
    }

    /// Splits the input text into sentences with a maximum of `maxWords` words.
    /// It prefers to split at a period (.), then a comma (,), and finally forcibly after `maxWords`.
    ///
    /// - Parameters:
    ///   - text: The input text to split.
    ///   - maxWords: The maximum number of words per sentence.
    /// - Returns: An array of sentence strings.
    func splitText(_ text: String, maxWords: Int) -> [String] {
        var sentences: [String] = []
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var currentIndex = 0
        let totalWords = words.count
        
        while currentIndex < totalWords {
            // Determine the range for the current chunk
            let endIndex = min(currentIndex + maxWords, totalWords)
            var chunk = words[currentIndex..<endIndex].joined(separator: " ")
            
            // Search for the last period within the chunk
            if let periodRange = chunk.range(of: ".", options: .backwards) {
                let sentence = String(chunk[..<periodRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                sentences.append(sentence)
                currentIndex += sentence.components(separatedBy: .whitespacesAndNewlines).count
            }
            // If no period, search for the last comma
            else if let commaRange = chunk.range(of: ",", options: .backwards) {
                let sentence = String(chunk[..<commaRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                sentences.append(sentence)
                currentIndex += sentence.components(separatedBy: .whitespacesAndNewlines).count
            }
            // If neither, forcibly break after maxWords
            else {
                sentences.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentIndex += maxWords
            }
        }
        
        return sentences
    }
    
    // Helper function to generate and play audio
    private func generateAudio(for text: String, sid: Int, speed: Double) {
        print("Generating audio for \(text)")
        let startTime = Date()
        guard let audio = tts?.generate(text: text, sid: sid, speed: Float(speed)) else {
            print("Error: TTS was never initialised")
            return
        }
        let endTime = Date()
        let generationTime = endTime.timeIntervalSince(startTime)
        print("Time taken for TTS generation: \(generationTime) seconds")
        
        realTimeAudioPlayer?.playAudioData(from: audio)
    }
    
    // Clean up resources
    @objc func deinitialize() {
        self.realTimeAudioPlayer?.stop()
        self.realTimeAudioPlayer = nil
    }
    
    // MARK: - AudioPlayerDelegate Method
    
    func didUpdateVolume(_ volume: Float) {
        // Emit the volume to JavaScript
        sendEvent(withName: "VolumeUpdate", body: ["volume": volume])
    }
}
