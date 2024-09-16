// AudioPlayer.swift

import Foundation
import AVFoundation
import Accelerate // For vDSP functions

class AudioPlayer: NSObject {
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
    weak var delegate: AudioPlayerDelegate?
    
    init(sampleRate: Double, channels: AVAudioChannelCount) {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)!
        audioQueue = []
        
        super.init()
        
        audioEngine.attach(audioPlayerNode)
        audioEngine.connect(audioPlayerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        // Add an audio tap to the main mixer node for volume monitoring
        addAudioTap()
        
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start AVAudioEngine: \(error)")
        }
        
        DispatchQueue.global(qos: .background).async {
            self.processAudioQueue()
        }
        
        // Start the volume update timer
        DispatchQueue.main.async {
            self.startVolumeTimer()
        }
    }
    
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
    
    private func processAudioQueue() {
        isProcessing = true
        while isProcessing {
            queueLock.lock()
            if !audioQueue.isEmpty {
                let data: Data = audioQueue.removeFirst()
                queueLock.unlock()
                
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(data.count) / audioFormat.streamDescription.pointee.mBytesPerFrame) else {
                    print("Failed to create AVAudioPCMBuffer")
                    continue
                }
                audioBuffer.frameLength = audioBuffer.frameCapacity
                
                // Cast the data pointer to Float type (assuming 32-bit float samples)
                data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    if let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: Float.self) {
                        let floatBuffer = audioBuffer.floatChannelData![0]
                        for i in 0..<Int(audioBuffer.frameLength) {
                            floatBuffer[i] = baseAddress[i]
                        }
                    }
                }
                
                audioPlayerNode.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)
                
                if !audioPlayerNode.isPlaying {
                    audioPlayerNode.play()
                }
            } else {
                queueLock.unlock()
                usleep(10000) // Sleep for 10ms to avoid busy waiting
            }
        }
    }
    
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
    
    private func startVolumeTimer() {
        volumeTimer = Timer.scheduledTimer(withTimeInterval: volumeUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.didUpdateVolume(self.currentVolume)
            }
        }
    }
    
    func stop() {
        isProcessing = false
        volumeTimer?.invalidate()
        audioEngine.stop()
        audioPlayerNode.stop()
    }
    
    deinit {
        stop()
        audioEngine.mainMixerNode.removeTap(onBus: 0)
    }
}
