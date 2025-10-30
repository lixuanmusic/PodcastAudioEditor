import SwiftUI

struct AudioAnalysisWindow: View {
    let result: AudioAnalysisResult
    @State private var selectedTab: String = "overview"
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("🎵 音频分析结果")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    NSApplication.shared.keyWindow?.close()
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            // 标签页
            Picker("分析类型", selection: $selectedTab) {
                Text("概览").tag("overview")
                Text("静音段").tag("silences")
                Text("响度变化").tag("loudness")
                Text("音乐/发言").tag("speech_music")
                Text("发言人").tag("speakers")
            }
            .pickerStyle(.segmented)
            .padding()
            
            // 内容区
            TabView(selection: $selectedTab) {
                OverviewTab(result: result)
                    .tag("overview")
                
                SilencesTab(silences: result.silences ?? [])
                    .tag("silences")
                
                LoudnessTab(segments: result.loudness_segments ?? [])
                    .tag("loudness")
                
                SpeechMusicTab(segments: result.speech_music ?? [])
                    .tag("speech_music")
                
                SpeakersTab(speakers: result.speaker_changes ?? [])
                    .tag("speakers")
            }
            
            Spacer()
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

// MARK: - 概览选项卡
struct OverviewTab: View {
    let result: AudioAnalysisResult
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 基本信息
                GroupBox(label: Label("基本信息", systemImage: "info.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("总时长:")
                            Spacer()
                            Text(formatTime(result.duration ?? 0))
                        }
                        HStack {
                            Text("采样率:")
                            Spacer()
                            Text("\(result.sample_rate ?? 0) Hz")
                        }
                    }
                }
                
                // 分析统计
                if let silences = result.silences {
                    GroupBox(label: Label("静音段", systemImage: "speaker.slash")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("数量: \(silences.count)")
                            if !silences.isEmpty {
                                let totalDuration = silences.reduce(0) { $0 + $1.duration }
                                Text("总时长: \(formatTime(totalDuration))")
                            }
                        }
                    }
                }
                
                if let loudness = result.loudness_segments {
                    GroupBox(label: Label("响度变化", systemImage: "waveform")) {
                        Text("检测到 \(loudness.count) 处响度变化")
                    }
                }
                
                if let speechMusic = result.speech_music {
                    GroupBox(label: Label("内容分类", systemImage: "music.note")) {
                        VStack(alignment: .leading, spacing: 4) {
                            let speechCount = speechMusic.filter { $0.type == "speech" }.count
                            let musicCount = speechMusic.filter { $0.type == "music" }.count
                            Text("发言: \(speechCount) 段")
                            Text("音乐: \(musicCount) 段")
                        }
                    }
                }
                
                if let speakers = result.speaker_changes {
                    GroupBox(label: Label("发言人变化", systemImage: "person.2")) {
                        Text("检测到 \(speakers.count) 次变化")
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - 静音段选项卡
struct SilencesTab: View {
    let silences: [Silence]
    
    var body: some View {
        List(silences, id: \.start) { silence in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("📍")
                    Text("\(formatTime(silence.start)) - \(formatTime(silence.end))")
                        .font(.caption)
                    Spacer()
                    Text(formatTime(silence.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 响度变化选项卡
struct LoudnessTab: View {
    let segments: [LoudnessChange]
    
    var body: some View {
        List(segments, id: \.time) { segment in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("📊")
                    Text(formatTime(segment.time))
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", segment.magnitude))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 音乐/发言选项卡
struct SpeechMusicTab: View {
    let segments: [SpeechMusicSegment]
    
    var body: some View {
        List(segments, id: \.start) { segment in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(segment.type == "speech" ? "🎤" : "🎵")
                    Text("\(formatTime(segment.start)) - \(formatTime(segment.end))")
                        .font(.caption)
                    Spacer()
                    Text(segment.type)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 发言人选项卡
struct SpeakersTab: View {
    let speakers: [SpeakerChange]
    
    var body: some View {
        List(speakers, id: \.time) { speaker in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("👤")
                    Text(formatTime(speaker.time))
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", speaker.distance))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - 辅助函数
func formatTime(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
    return String(format: "%02d:%02d.%03d", minutes, secs, ms)
}

#Preview {
    AudioAnalysisWindow(result: AudioAnalysisResult(
        success: true,
        error: nil,
        duration: 180,
        sample_rate: 22050,
        silences: [
            Silence(type: "silence", start: 0, end: 0.5, duration: 0.5),
            Silence(type: "silence", start: 30, end: 31, duration: 1)
        ],
        loudness_segments: [
            LoudnessChange(type: "loudness_change", time: 15, magnitude: 0.5)
        ],
        speech_music: [
            SpeechMusicSegment(type: "speech", start: 0, end: 90, confidence: 0.9),
            SpeechMusicSegment(type: "music", start: 90, end: 180, confidence: 0.8)
        ],
        speaker_changes: [
            SpeakerChange(type: "speaker_change", time: 45, distance: 2.5)
        ],
        segments: []
    ))
}
