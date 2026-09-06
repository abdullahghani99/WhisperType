import Foundation
import AVFoundation
import CoreMedia
func sample(_ rate: Double, _ offset: Int, _ frames: Int) -> CMSampleBuffer {
 let signal: [Float] = (offset..<offset+frames).map { Float(sin(2 * Double.pi * 440 * Double($0) / rate) * 0.5) }
 let data = signal.withUnsafeBytes { Data($0) }
 var block: CMBlockBuffer?
 precondition(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:data.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:data.count,flags:0,blockBufferOut:&block) == noErr)
 precondition(data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:data.count) } == noErr)
 var asbd = AudioStreamBasicDescription(mSampleRate:rate,mFormatID:kAudioFormatLinearPCM,mFormatFlags:41,mBytesPerPacket:4,mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:1,mBitsPerChannel:32,mReserved:0)
 var format: CMAudioFormatDescription?
 precondition(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format) == noErr)
 var result: CMSampleBuffer?
 precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format!,sampleCount:frames,presentationTimeStamp:CMTime(value:Int64(offset),timescale:Int32(rate)),packetDescriptions:nil,sampleBufferOut:&result) == noErr)
 return result!
}
let converter = MicrophonePCMConverter()
for rate in [24000.0, 48000.0, 24000.0] {
 var pcm = Data();let frames = Int(rate / 50)
 for n in 0..<50 { pcm.append(try converter.convert(sample(rate,n*frames,frames))) }
 let values: [Int16] = pcm.withUnsafeBytes { bytes in stride(from:0,to:bytes.count,by:2).map { bytes.loadUnaligned(fromByteOffset:$0,as:Int16.self) } }
 let rms = sqrt(values.reduce(0.0) { $0 + pow(Double($1)/32768,2) } / Double(values.count))
 let crossings = zip(values,values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
 precondition((15000...16500).contains(values.count), "Duration must remain one second at 16 kHz")
 precondition(rms > 0.30 && rms < 0.40, "Amplitude must survive native conversion")
 precondition((420...450).contains(crossings), "Frequency must remain 440 Hz")
 print("PASS native",rate,"Hz Float32 -> 16 kHz mono Int16; frames",values.count,"RMS",rms,"positive crossings",crossings)
}
print("No microphone opened; actual native conversion used with real CoreMedia buffers, including format changes.")
