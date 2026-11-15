import Accelerate
import Foundation
import NaturalLanguage

/// Sentence vectors from Apple's contextual embedding (on the device, many languages at once). Used to
/// find passages that mean the same as a question even when the words differ.
actor TextEmbedder {
    static let shared = TextEmbedder()

    private var embedding: NLContextualEmbedding?
    /// The model could not be loaded (no assets, old OS): everything falls back to word search.
    private var unavailable = false

    /// Length of the vectors, when the model is there.
    private(set) var dimension = 0

    private func prepare() async -> NLContextualEmbedding? {
        if let embedding { return embedding }
        guard !unavailable else { return nil }
        guard let model = NLContextualEmbedding(script: .latin) else {
            unavailable = true
            return nil
        }
        if !model.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult = await withCheckedContinuation { continuation in
                model.requestAssets { result, _ in continuation.resume(returning: result) }
            }
            guard result == .available else {
                unavailable = true
                return nil
            }
        }
        do {
            try model.load()
        } catch {
            unavailable = true
            return nil
        }
        embedding = model
        dimension = model.dimension
        return model
    }

    /// Whether vectors can be made at all (loads the model on first use).
    var isAvailable: Bool {
        get async { await prepare() != nil }
    }

    /// The vector of a text: the mean of its token vectors, normalized to length 1 (so a dot product is the cosine).
    func vector(for text: String) async -> [Float]? {
        guard let model = await prepare() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The model takes a limited number of tokens; a passage is short, a long one is cut.
        let input = String(trimmed.prefix(1500))
        guard let result = try? model.embeddingResult(for: input, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            vDSP.add(sum, vector, result: &sum)
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        var mean = vDSP.divide(sum, Double(count)).map(Float.init)
        let norm = sqrt(vDSP.dot(mean, mean))
        guard norm > 0 else { return nil }
        vDSP.divide(mean, norm, result: &mean)
        return mean
    }

    /// Cosine of two normalized vectors.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)
    }
}
