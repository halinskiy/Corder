import Foundation
import CoreML
import FluidAudio

/// Loads only local compiled artifacts. FluidAudio's normal loader can delete
/// a corrupt cache and download replacements, so Local only cannot call it.
enum CachedDiarizerModels {
    static func load(from root: URL = OfflineDiarizerModels.defaultModelsDirectory()) throws -> OfflineDiarizerModels {
        let repo = root.appendingPathComponent(Repo.diarizer.folderName)
        func model(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = cpuOnly ? .cpuOnly : .all
            return try MLModel(contentsOf: repo.appendingPathComponent(name), configuration: config)
        }
        let candidates = [root, root.appendingPathComponent("speaker-diarization"),
                          repo, root.appendingPathComponent("speaker-diarization-offline")]
        guard let parameters = candidates.map({ $0.appendingPathComponent("plda-parameters.json") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NetworkPolicy.Blocked(channel: .auxiliaryModels)
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: parameters)) as? [String: Any]
        guard let tensors = json?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !bytes.isEmpty, bytes.count % MemoryLayout<Float>.size == 0 else {
            throw NetworkPolicy.Blocked(channel: .auxiliaryModels)
        }
        var floats = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return try OfflineDiarizerModels(
            segmentationModel: model(ModelNames.OfflineDiarizer.segmentationPath),
            fbankModel: model(ModelNames.OfflineDiarizer.fbankPath, cpuOnly: true),
            embeddingModel: model(ModelNames.OfflineDiarizer.embeddingPath),
            pldaRhoModel: model(ModelNames.OfflineDiarizer.pldaRhoPath),
            pldaPsi: floats.map(Double.init), compilationDuration: 0)
    }
}
