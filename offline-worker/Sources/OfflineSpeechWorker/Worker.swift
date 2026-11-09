import Foundation
import WhisperKit

struct Request: Decodable {
    let id: String
    let pcm: String // 16 kHz mono Float32, little endian; bounded to 15 seconds.
}

@main struct OfflineSpeechWorker {
    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    static func main() async {
        guard [2, 5].contains(CommandLine.arguments.count) else { emit(["type":"error", "code":"model_missing"]); return }
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            guard FileManager.default.fileExists(atPath: model.appendingPathComponent("manifest.json").path),
                  FileManager.default.fileExists(atPath: model.appendingPathComponent("tokenizer.json").path) else {
                emit(["type":"error", "code":"model_missing"]); return
            }
            let loadedAt = ProcessInfo.processInfo.systemUptime
            emit(["type":"progress", "stage":"loading"])
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: model.path, tokenizerFolder: model,
                verbose: false, prewarm: false, load: true, download: false))
            if CommandLine.arguments.count == 5 {
                // Bounded post-meeting parts are supplied by the resumable Python worker.
                let language = CommandLine.arguments[4]
                let result = try await kit.transcribe(audioPath: CommandLine.arguments[2], decodeOptions:
                    DecodingOptions(task: .transcribe, language: language == "auto" ? nil : language,
                        temperatureFallbackCount: 2, detectLanguage: language == "auto", skipSpecialTokens: true,
                        withoutTimestamps: false, concurrentWorkerCount: 1, chunkingStrategy: .vad))
                let segments = result.flatMap(\.segments).map { segment -> [String: Any] in
                    ["start_seconds": Double(segment.start), "end_seconds": Double(segment.end),
                     "text": segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                     "needs_review": segment.compressionRatio > 2.4 || segment.avgLogprob < -1 || segment.noSpeechProb > 0.8]
                }
                let data = try JSONSerialization.data(withJSONObject: ["segments": segments])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
                emit(["type":"complete"])
                return
            }
            emit(["type":"progress", "stage":"warming"])
            // Finish lazy Core ML preparation before telling the app it is ready.
            // This contains no meeting audio and is never emitted as a caption.
            _ = try await kit.transcribe(audioArray: [Float](repeating: 0, count: 16000),
                decodeOptions: DecodingOptions(task: .transcribe, language: "zh", temperatureFallbackCount: 0,
                    sampleLength: 8, detectLanguage: false, skipSpecialTokens: true, concurrentWorkerCount: 1))
            emit(["type":"ready", "load_seconds":ProcessInfo.processInfo.systemUptime-loadedAt])
            var languages: [String:String] = [:]
            while let line = readLine() {
                guard line.utf8.count <= 1_400_000,
                      let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data),
                      let pcm = Data(base64Encoded: request.pcm), pcm.count % 4 == 0,
                      (1600*4...16000*15*4).contains(pcm.count) else {
                    emit(["type":"error", "code":"invalid_audio"]); continue
                }
                let samples: [Float] = pcm.withUnsafeBytes { raw in
                    stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
                }
                guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else {
                    emit(["type":"error", "id":request.id, "code":"invalid_audio"]); continue
                }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    // Transcribe rather than translate. Detect each utterance independently;
                    // no previous text prompt that could repeat or invent meeting content.
                    let detected: String
                    if let cached = languages[request.id] { detected = cached }
                    else {
                        detected = try await kit.detectLangauge(audioArray: samples).language
                        if languages.count >= 8 { languages.removeAll(keepingCapacity: true) }
                        languages[request.id] = detected
                    }
                    // This app's live mode is Chinese/English. Short noisy turns
                    // must not select Japanese (observed in the production log).
                    let language = detected == "en" ? "en" : "zh"
                    let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 1,
                        sampleLength: 160, detectLanguage: false, skipSpecialTokens: true,
                        withoutTimestamps: false, concurrentWorkerCount: 1)
                    let result = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                    let text = result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    let segments = result.flatMap(\.segments)
                    let unreliable = segments.contains { $0.compressionRatio > 2.4 || $0.avgLogprob < -1.0 || $0.noSpeechProb > 0.8 }
                        || text.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
                    emit(["type":"result", "id":request.id, "text":unreliable ? "" : text,
                          "needs_review":unreliable, "language":language,
                          "seconds":ProcessInfo.processInfo.systemUptime-began])
                } catch { emit(["type":"error", "id":request.id, "code":"decode_failed"]) }
            }
        } catch { emit(["type":"error", "code":"model_load_failed"]) }
    }
}
