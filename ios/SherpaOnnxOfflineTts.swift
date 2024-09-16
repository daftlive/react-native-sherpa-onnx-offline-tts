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
    private var tts = createOfflineTts() // Assuming createOfflineTts() is implemented elsewhere
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
    @objc(initializeWithSampleRate:channels:)
    func initializeWithSampleRate(_ sampleRate: Double, channels: Int) {
        self.realTimeAudioPlayer = AudioPlayer(sampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        self.realTimeAudioPlayer?.delegate = self // Set delegate to receive volume updates
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
        let audio = tts.generate(text: text, sid: sid, speed: Float(speed))
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
