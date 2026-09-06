import Foundation

extension StudioSnapshot {
    public init(sessionID: UUID, revision: Int64, selectedSceneID: String) {
        self.init(sessionID: sessionID, revision: revision, selectedSceneID: selectedSceneID, scenes: Scene.examples)
    }
}
