import Foundation

// 分析结果的数据模型
struct AudioAnalysisResult: Codable {
    let success: Bool
    let error: String?
    let duration: Double?
    let sample_rate: Int?
    let silences: [Silence]?
    let loudness_segments: [LoudnessChange]?
    let speech_music: [SpeechMusicSegment]?
    let speaker_changes: [SpeakerChange]?
    let segments: [AnalysisSegment]?
}

struct Silence: Codable {
    let type: String  // "silence"
    let start: Double
    let end: Double
    let duration: Double
}

struct LoudnessChange: Codable {
    let type: String  // "loudness_change"
    let time: Double
    let magnitude: Double
}

struct SpeechMusicSegment: Codable {
    let type: String  // "speech" or "music"
    let start: Double
    let end: Double
    let confidence: Double
}

struct SpeakerChange: Codable {
    let type: String  // "speaker_change"
    let time: Double
    let distance: Double
}

struct AnalysisSegment: Codable {
    let type: String
    let start: Double?
    let end: Double?
    let time: Double?
    let duration: Double?
    let magnitude: Double?
    let confidence: Double?
    let distance: Double?
}

class AudioAnalyzer {
    static let shared = AudioAnalyzer()
    
    private var pythonScriptPath: String {
        // 获取应用包路径
        if let bundlePath = Bundle.main.resourcePath {
            return "\(bundlePath)/audio_analysis.py"
        }
        // 开发环境下的路径
        return "/Users/lixuan/Code_local/podcast_audio/PodcastAudioEditor/audio_analysis.py"
    }
    
    /// 分析音频文件
    /// - Parameters:
    ///   - filePath: 音频文件路径
    ///   - completion: 完成回调，返回分析结果或错误
    func analyzeAudio(filePath: String, completion: @escaping (AudioAnalysisResult?, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [self.pythonScriptPath, filePath]
            
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                
                if let jsonString = String(data: data, encoding: .utf8) {
                    if let jsonData = jsonString.data(using: .utf8) {
                        let decoder = JSONDecoder()
                        let result = try decoder.decode(AudioAnalysisResult.self, from: jsonData)
                        DispatchQueue.main.async {
                            completion(result, nil)
                        }
                        return
                    }
                }
                
                DispatchQueue.main.async {
                    let error = NSError(domain: "AudioAnalyzer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse analysis result"])
                    completion(nil, error)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(nil, error)
                }
            }
        }
    }
}
