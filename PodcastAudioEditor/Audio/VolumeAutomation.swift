import Foundation

// 自动化音量控制点
struct AutomationPoint: Identifiable, Codable {
    let id: UUID
    var time: TimeInterval  // 秒数
    var dbValue: Double     // -12.0 ~ 12.0
    
    init(time: TimeInterval, dbValue: Double) {
        self.id = UUID()
        self.time = time
        self.dbValue = max(-12.0, min(12.0, dbValue))  // 限制范围
    }
}

// 音量自动化管理
class VolumeAutomation: ObservableObject {
    @Published var points: [AutomationPoint] = []
    @Published var selectedPointId: UUID?
    
    let minDb: Double = -12.0
    let maxDb: Double = 12.0
    
    func addPoint(time: TimeInterval, dbValue: Double) {
        let point = AutomationPoint(time: time, dbValue: dbValue)
        points.append(point)
        points.sort { $0.time < $1.time }
        selectedPointId = point.id
    }
    
    func updatePoint(_ id: UUID, time: TimeInterval, dbValue: Double) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            points[index].time = time
            points[index].dbValue = max(minDb, min(maxDb, dbValue))
            points.sort { $0.time < $1.time }
        }
    }
    
    func deletePoint(_ id: UUID) {
        points.removeAll { $0.id == id }
        if selectedPointId == id {
            selectedPointId = nil
        }
    }
    
    func deleteSelectedPoint() {
        if let id = selectedPointId {
            deletePoint(id)
        }
    }
    
    func getVolumeAtTime(_ time: TimeInterval) -> Double {
        guard !points.isEmpty else { return 0.0 }
        
        // 找到最接近的两个点
        let beforePoints = points.filter { $0.time <= time }
        let afterPoints = points.filter { $0.time >= time }
        
        guard let before = beforePoints.last else {
            // 在第一个点之前
            return points.first?.dbValue ?? 0.0
        }
        
        guard let after = afterPoints.first else {
            // 在最后一个点之后
            return points.last?.dbValue ?? 0.0
        }
        
        if before.time == after.time {
            return before.dbValue
        }
        
        // 线性插值
        let ratio = (time - before.time) / (after.time - before.time)
        return before.dbValue + (after.dbValue - before.dbValue) * ratio
    }
    
    func clear() {
        points.removeAll()
        selectedPointId = nil
    }
}
