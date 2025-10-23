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
        return ["VolumeUpdate"]
    }
    
    // Initialize TTS and Audio Player
    @objc(initializeTTS:channels:modelId:)
    func initializeTTS(_ sampleRate: Double, channels: Int, modelId: String) {
        self.realTimeAudioPlayer = AudioPlayer(sampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        self.realTimeAudioPlayer?.delegate = self // Set delegate to receive volume updates
        self.tts = createOfflineTts(modelId: modelId)
    }

    // Generate audio and return as base64 string
    @objc(generate:sid:speed:resolver:rejecter:)
    func generate(_ text: String, sid: Int, speed: Double, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedText.isEmpty else {
            rejecter("EMPTY_TEXT", "Input text is empty", nil)
            return
        }
        
        print("Generating audio for text with \(trimmedText.split(separator: " ").count) words")
        
        // Split the text into manageable sentences
        let sentences = splitText(trimmedText, maxWords: 15)
        print("Split into \(sentences.count) sentences")
        
        var allSamples: [Float] = []
        var sampleRate: Int32 = 0
        
        for (index, sentence) in sentences.enumerated() {
            let processedSentence = sentence.hasSuffix(".") ? sentence : "\(sentence)."
            
            print("Generating chunk \(index + 1)/\(sentences.count): '\(processedSentence)'")
            
            guard let audio = tts?.generate(text: processedSentence, sid: sid, speed: Float(speed)) else {
                rejecter("TTS_ERROR", "TTS generation failed for sentence: \(processedSentence)", nil)
                return
            }
            
            if sampleRate == 0 {
                sampleRate = audio.sampleRate
            }
            
            let samplesCount = Int(audio.n)
            print("Generated \(samplesCount) samples at \(sampleRate)Hz")
            
            // Create array from pointer without extra copying
            let samplesArray = Array(UnsafeBufferPointer(start: audio.samples, count: samplesCount))
            allSamples.append(contentsOf: samplesArray)
        }
        
        print("Total samples: \(allSamples.count) at \(sampleRate)Hz")
        print("Duration: \(Float(allSamples.count) / Float(sampleRate)) seconds")
        
        // Convert combined audio samples to Data - use withUnsafeBytes for efficiency
        let audioData = allSamples.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
        let base64String = audioData.base64EncodedString()
        
        print("Base64 size: \(base64String.count) chars")
        
        let result: [String: Any] = [
            "audioData": base64String,
            "sampleRate": Int(sampleRate)
        ]
        
        resolver(result)
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
