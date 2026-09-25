import Accelerate
import Foundation

nonisolated struct MathService {
    static func sliceMatrix(probs: [Float], frames: Int, vocabSize: Int, startFrame: Int, endFrame: Int) -> ([Float], Int)? {
        let validStart = max(0, startFrame)
        let validEnd = min(frames, endFrame)
        if validStart >= validEnd { return nil }
        
        let newFrames = validEnd - validStart
        let sliceStart = validStart * vocabSize
        let sliceEnd = validEnd * vocabSize
        
        let slice = Array(probs[sliceStart..<sliceEnd])
        return (slice, newFrames)
    }
    
    static func softmaxVectorized(logits: UnsafeMutablePointer<Float>, frameCount: Int, vocabSize: Int) -> [Float] {
        var probabilities = [Float](repeating: 0.0, count: frameCount * vocabSize)
        
        var expIn = [Float](repeating: 0.0, count: vocabSize)
        var expOut = [Float](repeating: 0.0, count: vocabSize)
        var count = Int32(vocabSize)

        for f in 0..<frameCount {
            let offset = f * vocabSize
            let frameData = logits.advanced(by: offset)

            var maxVal: Float = 0.0
            vDSP_maxv(frameData, 1, &maxVal, vDSP_Length(vocabSize))
            var negMax = -maxVal

            vDSP_vsadd(frameData, 1, &negMax, &expIn, 1, vDSP_Length(vocabSize))
            
            vvexpf(&expOut, expIn, &count)

            var sum: Float = 0.0
            vDSP_sve(expOut, 1, &sum, vDSP_Length(vocabSize))

            let probsData = probabilities.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: offset) }
            vDSP_vsdiv(expOut, 1, &sum, probsData, 1, vDSP_Length(vocabSize))
        }
        return probabilities
    }
    
    static func cosineDistance(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, length: Int) -> Float {
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(length))
        vDSP_svesq(a, 1, &normA, vDSP_Length(length))
        vDSP_svesq(b, 1, &normB, vDSP_Length(length))
        
        let denom = sqrt(normA) * sqrt(normB)
        if denom == 0 { return 1.0 }
        return 1.0 - (dotProduct / denom)
    }

    static func computeDTW(seqA: [Float], framesA: Int, seqB: [Float], framesB: Int, vocabSize: Int) -> Float {
        if framesA == 0 || framesB == 0 { return 0 }
        
        var costMatrix = [Float](repeating: Float.greatestFiniteMagnitude, count: (framesA + 1) * (framesB + 1))
        costMatrix[0] = 0
        
        seqA.withUnsafeBufferPointer { ptrA in
            seqB.withUnsafeBufferPointer { ptrB in
                for i in 1...framesA {
                    let vecA = ptrA.baseAddress!.advanced(by: (i - 1) * vocabSize)
                    for j in 1...framesB {
                        let vecB = ptrB.baseAddress!.advanced(by: (j - 1) * vocabSize)
                        let cost = cosineDistance(vecA, vecB, length: vocabSize)
                        
                        let match = costMatrix[(i - 1) * (framesB + 1) + (j - 1)]
                        let insert = costMatrix[(i - 1) * (framesB + 1) + j]
                        let delete = costMatrix[i * (framesB + 1) + (j - 1)]
                        
                        costMatrix[i * (framesB + 1) + j] = cost + min(match, min(insert, delete))
                    }
                }
            }
        }
        
        return costMatrix[framesA * (framesB + 1) + framesB] / Float(framesA + framesB)
    }
}
