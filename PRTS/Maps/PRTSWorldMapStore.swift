import Foundation
import ARKit

@MainActor
final class PRTSWorldMapStore: ObservableObject {
    struct SavedMap: Identifiable, Codable {
        let id: UUID
        let name: String
        let worldMapFilename: String
        let routeFilename: String?
        let createdAt: Date
    }

    @Published private(set) var maps: [SavedMap] = []
    private let directory: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        directory = documents.appendingPathComponent("PRTSMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
    }

    func save(worldMap: ARWorldMap, name: String, routes: [PRTSRouteSegment] = []) throws -> SavedMap {
        let id = UUID()
        let worldFile = "\(id.uuidString).worldmap"
        let routeFile = routes.isEmpty ? nil : "\(id.uuidString).routes.json"
        let worldURL = directory.appendingPathComponent(worldFile)
        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try data.write(to: worldURL, options: .atomic)
        if let routeFile {
            let routeData = try JSONEncoder().encode(routes)
            try routeData.write(to: directory.appendingPathComponent(routeFile), options: .atomic)
        }
        let map = SavedMap(id: id, name: name, worldMapFilename: worldFile, routeFilename: routeFile, createdAt: Date())
        maps.insert(map, at: 0)
        saveIndex()
        return map
    }

    func loadWorldMap(_ map: SavedMap) throws -> ARWorldMap {
        let data = try Data(contentsOf: directory.appendingPathComponent(map.worldMapFilename))
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return worldMap
    }

    func loadRoutes(_ map: SavedMap) throws -> [PRTSRouteSegment] {
        guard let filename = map.routeFilename else { return [] }
        return try JSONDecoder().decode([PRTSRouteSegment].self, from: Data(contentsOf: directory.appendingPathComponent(filename)))
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func loadIndex() { maps = (try? JSONDecoder().decode([SavedMap].self, from: Data(contentsOf: indexURL))) ?? [] }
    private func saveIndex() { try? JSONEncoder().encode(maps).write(to: indexURL, options: .atomic) }
}
