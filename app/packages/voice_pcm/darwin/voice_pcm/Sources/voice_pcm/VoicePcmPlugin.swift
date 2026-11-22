// Decodes a voice clip to 16 kHz mono Float32 with AVAudioFile and AVAudioConverter.
import AVFoundation

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

public class VoicePcmPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "voice_pcm", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(VoicePcmPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "decode",
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    DispatchQueue.global(qos: .utility).async {
      do {
        let samples = try VoicePcmPlugin.decode(path)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        DispatchQueue.main.async {
          result(["samples": FlutterStandardTypedData(float32: data), "sampleRate": 16000])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "decode_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  static func decode(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard
      let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: file.processingFormat, to: target)
    else {
      throw NSError(domain: "voice_pcm", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported audio format"])
    }
    let inChunk: AVAudioFrameCount = 8192
    let outChunk = AVAudioFrameCount(Double(inChunk) * 16000 / file.processingFormat.sampleRate) + 1024
    var out: [Float] = []
    out.reserveCapacity(Int(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1)
    var readError: Error?
    var ended = false
    while true {
      guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outChunk) else { break }
      var convError: NSError?
      let status = converter.convert(to: buffer, error: &convError) { _, inputStatus in
        if ended {
          inputStatus.pointee = .endOfStream
          return nil
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inChunk) else {
          inputStatus.pointee = .endOfStream
          return nil
        }
        do {
          try file.read(into: input, frameCount: inChunk)
        } catch {
          readError = error
          ended = true
          inputStatus.pointee = .endOfStream
          return nil
        }
        if input.frameLength == 0 {
          ended = true
          inputStatus.pointee = .endOfStream
          return nil
        }
        inputStatus.pointee = .haveData
        return input
      }
      if let e = convError ?? readError { throw e }
      if let ch = buffer.floatChannelData, buffer.frameLength > 0 {
        out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
      }
      if status == .endOfStream || status == .error { break }
    }
    return out
  }
}
