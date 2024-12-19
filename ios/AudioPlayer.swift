// AudioPlayer.swift

import Foundation
import AVFoundation
import Accelerate // For vDSP functions

class AudioPlayer: NSObject {
    // MARK: - Properties

    private var audioEngine: AVAudioEngine
    private var audioPlayerNode: AVAudioPlayerNode
    private var audioFormat: AVAudioFormat
    private var audioQueue: [Data]
    private let queueLock = NSLock()
    private var isProcessing = false

    // Volume Monitoring
    private var volumeTimer: Timer?
    private var currentVolume: Float = 0.0
    private let volumeUpdateInterval: TimeInterval = 0.2 // 0.2 seconds

    // Delegate to communicate with TTSManager
    weak var delegate: AudioPlayerDelegate? // Assuming AudioPlayerDelegate is defined elsewhere

    // MARK: - Initialization

    init(sampleRate: Double, channels: AVAudioChannelCount) {
        // Initialize properties
        self.audioEngine = AVAudioEngine()
        self.audioPlayerNode = AVAudioPlayerNode()
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        )!
        self.audioQueue = []

        super.init()

        // Set up AVAudioSession
        setupAudioSession()

        // Set up audio engine and player node
        setupAudioEngine()

        // Observe audio session interruptions
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        // Start processing the audio queue
        DispatchQueue.global(qos: .background).async {
            self.processAudioQueue()
        }

        // Start the volume update timer
        DispatchQueue.main.async {
            self.startVolumeTimer()
        }
    }

    deinit {
        // Clean up resources
        stop()
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        NotificationCenter.default.removeObserver(self)
        deactivateAudioSession()
    }

    // MARK: - Audio Session Setup

    /// Sets up the AVAudioSession with the desired category and activates it.
    private func setupAudioSession() {
    do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        print("Audio session set up successfully")
    } catch {
        print("Failed to set up AVAudioSession: \(error)")
    }
}

    /// Deactivates the AVAudioSession.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            print("Audio session deactivated")
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    // MARK: - Audio Engine Setup

    /// Sets up the audio engine and attaches the player node.
    private func setupAudioEngine() {
        // Attach and connect the audio player node
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        // Add an audio tap for volume monitoring
        addAudioTap()

        // Start the audio engine
        do {
            try audioEngine.start()
            print("Audio engine started successfully")
        } catch {
            print("Failed to start AVAudioEngine: \(error)")
        }
    }

    // MARK: - Play Audio Data

    /// Adds audio data to the queue to be played.
    /// - Parameter audio: The audio data wrapper containing samples.
    func playAudioData(from audio: SherpaOnnxGeneratedAudioWrapper) {
        // Create a Data object from samples safely
        let sampleCount = Int(audio.n)
        let samples = audio.samples
        let data = Data(bytes: samples, count: sampleCount * MemoryLayout<Float>.size)

        // Lock the queue, append data, then unlock
        queueLock.lock()
        audioQueue.append(data)
        queueLock.unlock()
    }

    // MARK: - Process Audio Queue

    /// Continuously processes the audio queue and schedules buffers for playback.
    private func processAudioQueue() {
        isProcessing = true
        while isProcessing {
            queueLock.lock()
            if !audioQueue.isEmpty {
                let data = audioQueue.removeFirst()
                queueLock.unlock()

                guard let audioBuffer = AVAudioPCMBuffer(
                    pcmFormat: audioFormat,
                    frameCapacity: AVAudioFrameCount(data.count) / audioFormat.streamDescription.pointee.mBytesPerFrame
                ) else {
                    print("Failed to create AVAudioPCMBuffer")
                    continue
                }
                audioBuffer.frameLength = audioBuffer.frameCapacity

                // Copy data into the audio buffer
                data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    if let baseAddress = buffer.baseAddress {
                        let audioBufferPointer = audioBuffer.floatChannelData![0]
                        let dataPointer = baseAddress.assumingMemoryBound(to: Float.self)
                        audioBufferPointer.assign(from: dataPointer, count: Int(audioBuffer.frameLength))
                    }
                }

                // Schedule the buffer for playback
                audioPlayerNode.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)

                // Start the audio player node if not already playing
                if !audioPlayerNode.isPlaying {
                    audioPlayerNode.play()
                    print("Audio player node started playing")
                }
            } else {
                queueLock.unlock()
                usleep(10000) // Sleep for 10ms to avoid busy waiting
            }
        }
    }

    // MARK: - Volume Monitoring

    /// Adds an audio tap to the main mixer node to monitor the output volume.
    private func addAudioTap() {
        let mixer = audioEngine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: mixer.outputFormat(forBus: 0)) { [weak self] (buffer, time) in
            guard let self = self else { return }

            // Calculate RMS for the buffer
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            var rms: Float = 0.0

            if let channelData = buffer.floatChannelData {
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    var channelSum: Float = 0.0
                    vDSP_rmsqv(samples, 1, &channelSum, vDSP_Length(frameLength))
                    rms += channelSum
                }
                rms /= Float(channelCount)
                self.currentVolume = rms
            }
        }
    }

    /// Starts a timer to periodically update the delegate with the current volume.
    private func startVolumeTimer() {
        volumeTimer = Timer.scheduledTimer(withTimeInterval: volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.didUpdateVolume(self.currentVolume)
            }
        }
    }

    // MARK: - Interruption Handling

    /// Handles audio session interruptions (e.g., incoming calls).
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began, pause audio playback
            print("Audio session interruption began")
            if audioPlayerNode.isPlaying {
                audioPlayerNode.pause()
                print("Audio player node paused")
            }
        case .ended:
            // Interruption ended, reactivate session and resume playback
            print("Audio session interruption ended")

            // Retrieve interruption options to check if we should resume playback
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Reactivate the audio session with the correct category and options
                    do {
                        let session = AVAudioSession.sharedInstance()
                        // Reset category and options
                        try session.setCategory(.playback, mode: .default, options: [])
                        try session.setActive(true)
                        print("Audio session reactivated with proper category and options after interruption")

                        // Restart the audio engine if necessary
                        if !audioEngine.isRunning {
                            try audioEngine.start()
                            print("Audio engine restarted after interruption")
                        }

                        // Resume playback if there are buffers to play
                        if !audioPlayerNode.isPlaying && !audioQueue.isEmpty {
                            audioPlayerNode.play()
                            print("Audio player node resumed playback after interruption")
                        }
                    } catch {
                        print("Failed to reactivate audio session or restart audio engine: \(error)")
                    }
                } else {
                    print("Interruption ended, but should not resume playback")
                }
            } else {
                print("Interruption ended without interruption options")
            }
        @unknown default:
            break
        }
    }

    // MARK: - Stop Audio Playback

    /// Stops audio playback and processing.
    func stop() {
        isProcessing = false
        volumeTimer?.invalidate()
        audioEngine.stop()
        audioPlayerNode.stop()
        print("Audio playback stopped")
    }
}
