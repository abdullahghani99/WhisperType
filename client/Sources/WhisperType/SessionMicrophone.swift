import AVFoundation
import CoreMedia
import Foundation

/// Input-only capture avoids coupling a Bluetooth microphone to AVAudioEngine's
/// output graph while the headset switches between playback and microphone modes.
final class SessionMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let callbackQueue = DispatchQueue(label: "app.whispertype.client.input-samples")
    private var errorObserver: NSObjectProtocol?
    private let pcm = MicrophonePCMConverter()
    private var reportedConversionError = false
    var onPCM: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Called only on the recorder's owned hardware queue. Every blocking setup
    /// operation is followed by an ownership check before it can start capture.
    func start(device: AudioInputDevice, isCurrent: () -> Bool) throws -> Bool {
        guard isCurrent() else { return false }
        guard let selected = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == device.uid }) else {
            throw NSError(domain: "whispertype.audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Selected Bluetooth microphone is no longer available."])
        }
        guard isCurrent() else { return false }
        let input = try AVCaptureDeviceInput(device: selected)
        guard isCurrent() else { return false }
        // Preserve the device's native format. AirPods delivered real 24 kHz
        // Float32 samples while a requested 16 kHz Int16 output yielded silence.
        // Convert only after the native sample buffer reaches this process.
        output.audioSettings = nil
        output.setSampleBufferDelegate(self, queue: callbackQueue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "whispertype.audio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not configure the selected microphone."])
        }
        session.addInput(input); session.addOutput(output); session.commitConfiguration()
        guard isCurrent() else { stop(); return false }
        errorObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                                                               object: session, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                ?? "Microphone capture was interrupted."
            // Never stop/deallocate a session on its internal notification queue.
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
        }
        session.startRunning()
        guard isCurrent() else { stop(); return false }
        return session.isRunning
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        if let observer = errorObserver { NotificationCenter.default.removeObserver(observer); errorObserver = nil }
        session.stopRunning()
        for input in session.inputs { session.removeInput(input) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            let data = try pcm.convert(sampleBuffer)
            if !data.isEmpty { onPCM?(data) }
        } catch {
            guard !reportedConversionError else { return }
            reportedConversionError = true
            DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) }
        }
    }
}

/// One converter per serial sample queue, rebuilt only if the input format changes.
final class MicrophonePCMConverter {
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?

    func convert(_ sample: CMSampleBuffer) throws -> Data {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw failure("Microphone returned an unsupported audio format.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(Int32.max),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return Data() }
        input.frameLength = AVAudioFrameCount(frames)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard copied == noErr else { throw failure("Could not read microphone samples (\(copied)).") }
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: output)
        }
        guard let converter = converter else { throw failure("Could not convert microphone audio.") }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * output.sampleRate / format.sampleRate)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return Data() }
        var fed = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            guard !fed else { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return input
        }
        if let error = error { throw error }
        guard status != .error else { throw failure("Microphone audio conversion failed.") }
        guard let channel = converted.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(converted.frameLength) * 2)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "whispertype.audio", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
