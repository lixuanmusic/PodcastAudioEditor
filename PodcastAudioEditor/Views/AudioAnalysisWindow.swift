import SwiftUI

struct AudioAnalysisWindow: View {
    @ObservedObject var analysisVM: AudioAnalysisViewModel
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab = 0
    @State private var selectedSegmentIndex: Int? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("🎵 音频分析结果")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .border(width: 1, edges: [.bottom], color: Color(NSColor.separatorColor))
            
            if analysisVM.isAnalyzing {
                // 分析进度
                VStack(spacing: 12) {
                    ProgressView(value: analysisVM.analysisProgress)
                        .tint(.blue)
                    Text("分析进度: \(Int(analysisVM.analysisProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                TabView(selection: $selectedTab) {
                    // Tab 1: 统计概览
                    StatisticsView(analysisVM: analysisVM)
                        .tabItem {
                            Label("统计", systemImage: "chart.bar")
                        }
                        .tag(0)
                    
                    // Tab 2: 段落列表
                    SegmentsListView(
                        segments: analysisVM.segments,
                        selectedIndex: $selectedSegmentIndex
                    )
                    .tabItem {
                        Label("段落", systemImage: "list.bullet")
                    }
                    .tag(1)
                    
                    // Tab 3: 特征曲线
                    FeaturesChartView(features: analysisVM.features)
                    .tabItem {
                        Label("特征", systemImage: "waveform.circle")
                    }
                    .tag(2)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

// MARK: - 统计概览视图
struct StatisticsView: View {
    @ObservedObject var analysisVM: AudioAnalysisViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 时长统计
                GroupBox(label: Label("时长统计", systemImage: "hourglass.circle")) {
                    VStack(alignment: .leading, spacing: 10) {
                        StatisticRow(
                            label: "总语音时长",
                            value: formatDuration(analysisVM.totalSpeechDuration),
                            color: .blue
                        )
                        Divider()
                        StatisticRow(
                            label: "总音乐时长",
                            value: formatDuration(analysisVM.totalMusicDuration),
                            color: .green
                        )
                        Divider()
                        StatisticRow(
                            label: "总静音时长",
                            value: formatDuration(analysisVM.totalSilenceDuration),
                            color: .gray
                        )
                    }
                    .padding(8)
                }
                
                // 特征统计
                GroupBox(label: Label("平均特征", systemImage: "chart.line.uptrend.xyaxis")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("平均能量")
                            Spacer()
                            Text(String(format: "%.1f dB", analysisVM.averageEnergy))
                                .fontWeight(.semibold)
                                .monospaced()
                        }
                        Divider()
                        HStack {
                            Text("平均零交叉率")
                            Spacer()
                            Text(String(format: "%.3f", analysisVM.averageZCR))
                                .fontWeight(.semibold)
                                .monospaced()
                        }
                    }
                    .padding(8)
                }
                
                // 段落统计
                GroupBox(label: Label("段落统计", systemImage: "square.split.2x2")) {
                    VStack(alignment: .leading, spacing: 10) {
                        let (silenceCount, speechCount, musicCount) = getSegmentCounts()
                        
                        HStack {
                            Text("语音段落")
                            Spacer()
                            Text("\(speechCount)")
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                        }
                        Divider()
                        HStack {
                            Text("音乐段落")
                            Spacer()
                            Text("\(musicCount)")
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                        Divider()
                        HStack {
                            Text("静音段落")
                            Spacer()
                            Text("\(silenceCount)")
                                .fontWeight(.semibold)
                                .foregroundStyle(.gray)
                        }
                    }
                    .padding(8)
                }
                
                Spacer()
            }
            .padding(12)
        }
    }
    
    private func getSegmentCounts() -> (Int, Int, Int) {
        let silence = analysisVM.segments.filter { $0.type == .silence }.count
        let speech = analysisVM.segments.filter { $0.type == .speech }.count
        let music = analysisVM.segments.filter { $0.type == .music }.count
        return (silence, speech, music)
    }
}

// MARK: - 统计行
struct StatisticRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospaced()
        }
    }
}

// MARK: - 段落列表视图
struct SegmentsListView: View {
    let segments: [Segment]
    @Binding var selectedIndex: Int?
    
    var body: some View {
        List(segments.indices, id: \.self, selection: $selectedIndex) { idx in
            let segment = segments[idx]
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    segmentTypeIcon(segment.type)
                    Text(segmentTypeName(segment.type))
                        .fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%.0f%%", segment.confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 8) {
                    Text(String(format: "%.2f - %.2f s", segment.startTime, segment.endTime))
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatDuration(segment.duration))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func segmentTypeIcon(_ type: SegmentType) -> some View {
        let (symbol, color) = segmentTypeSymbol(type)
        return Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(color)
    }
    
    private func segmentTypeSymbol(_ type: SegmentType) -> (String, Color) {
        switch type {
        case .silence: return ("circle.slash", .gray)
        case .speech: return ("mic.fill", .blue)
        case .music: return ("music.note", .green)
        case .noise: return ("waveform", .orange)
        case .unknown: return ("questionmark.circle", .secondary)
        }
    }
    
    private func segmentTypeName(_ type: SegmentType) -> String {
        switch type {
        case .silence: return "静音"
        case .speech: return "语音"
        case .music: return "音乐"
        case .noise: return "噪音"
        case .unknown: return "未知"
        }
    }
}

// MARK: - 特征曲线视图
struct FeaturesChartView: View {
    let features: [AcousticFeatures]
    @State private var selectedMetric = 0
    
    let metrics = ["能量", "零交叉率", "谱质心"]
    
    var body: some View {
        VStack {
            Picker("特征", selection: $selectedMetric) {
                ForEach(metrics.indices, id: \.self) { idx in
                    Text(metrics[idx]).tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            
            Canvas { context, size in
                drawChart(context: context, size: size)
            }
            .padding(12)
        }
    }
    
    private func drawChart(context: GraphicsContext, size: CGSize) {
        guard !features.isEmpty else { return }
        
        let padding: CGFloat = 40
        let chartWidth = size.width - 2 * padding
        let chartHeight = size.height - 2 * padding
        
        // 提取数据
        let values: [Float]
        let maxValue: Float
        let minValue: Float
        
        switch selectedMetric {
        case 0:  // 能量
            values = features.map { $0.energy }
            maxValue = values.max() ?? 0
            minValue = values.min() ?? -80
        case 1:  // ZCR
            values = features.map { $0.zcr }
            maxValue = 0.5
            minValue = 0
        case 2:  // 谱质心
            values = features.map { $0.spectralCentroid }
            maxValue = (values.max() ?? 8000) * 1.1
            minValue = 0
        default:
            return
        }
        
        // 绘制背景
        context.fill(
            Path(roundedRect: CGRect(x: padding, y: padding, width: chartWidth, height: chartHeight), cornerRadius: 4),
            with: .color(.gray.opacity(0.05))
        )
        
        // 绘制曲线
        let range = maxValue - minValue
        guard range > 0 else { return }
        
        var path = Path()
        for (idx, value) in values.enumerated() {
            let x = padding + CGFloat(idx) / CGFloat(values.count) * chartWidth
            let normalizedValue = CGFloat(value - minValue) / CGFloat(range)
            let y = padding + chartHeight * (1 - normalizedValue)
            
            if idx == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        context.stroke(path, with: .color(.blue), lineWidth: 1.5)
    }
}

// MARK: - 辅助函数
func formatDuration(_ seconds: Double) -> String {
    let minutes = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", minutes, secs)
}

extension View {
    func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
        overlay(alignment: .top) {
            if edges.contains(.top) {
                color.frame(height: width)
            }
        }
        .overlay(alignment: .bottom) {
            if edges.contains(.bottom) {
                color.frame(height: width)
            }
        }
    }
}
