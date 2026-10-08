import Foundation

// MARK: - Utility

@usableFromInline
@inline(__always)
func loadBE32(_ p: UnsafePointer<UInt8>) -> UInt64 {
    let b0 = UInt64(p[0]) << 24
    let b1 = UInt64(p[1]) << 16
    let b2 = UInt64(p[2]) << 8
    let b3 = UInt64(p[3])
    return b0 | b1 | b2 | b3
}

@inline(__always)
func adjustThresholdUp(_ t: UInt32) -> UInt32 {
    return (t &- ((t &+ 0x1f) >> 5)) &+ 0x40
}

@inline(__always)
func adjustThresholdDown(_ t: UInt32) -> UInt32 {
    return t &- (t >> 5)
}

// MARK: - BinaryArithmeticDecoder

final class BinaryArithmeticDecoder {
    static let centerThreshold: UInt32 = 0x400
    
    private let inputBuffer: [UInt8] // Keeps memory alive
    private let inputPtr: UnsafePointer<UInt8>
    private var idx: Int = 0
    private var scale: UInt64 = 0xFFFFFFFF
    private var value: UInt64 = 0
    
    init?(byteInput: [UInt8]) {
        guard byteInput.count >= 4 else { return nil }
        
        value = (UInt64(byteInput[0]) << 24) |
        (UInt64(byteInput[1]) << 16) |
        (UInt64(byteInput[2]) << 8)  |
        UInt64(byteInput[3])
        
        var padded = Array(byteInput[4...])
        padded.append(contentsOf: [0, 0, 0, 0])
        self.inputBuffer = padded
        self.inputPtr = padded.withUnsafeBufferPointer { $0.baseAddress! }
    }
    
    @inline(__always)
    private func nextByte() -> UInt8 {
        let b = inputPtr[idx]
        idx &+= 1
        return b
    }
    
    @inline(__always)
    func getBit(threshold: UInt32) -> Int {
        while scale < 0x0100_0000 {
            scale <<= 8
            value = (value << 8) | UInt64(nextByte())
        }
        
        let scaledThreshold = (scale >> 11) &* UInt64(threshold)
        if value < scaledThreshold {
            scale = scaledThreshold
            return 0
        } else {
            value &-= scaledThreshold
            scale &-= scaledThreshold
            return 1
        }
    }
    
    @inline(__always)
    func getRawBit() -> Int {
        while scale < 0x0100_0000 {
            scale <<= 8
            value = (value << 8) | UInt64(nextByte())
        }
        
        scale >>= 1
        if value < scale { return 0 }
        value &-= scale
        return 1
    }
}

// MARK: - MSBFirstGetter

final class MSBFirstGetter {
    private let thresholds: UnsafeMutableBufferPointer<UInt32>
    private let bitCount: Int
    
    init(bitCount: Int) {
        self.bitCount = bitCount
        let total = (1 << bitCount) - 1
        let ptr = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: total)
        ptr.initialize(repeating: 0x400)
        self.thresholds = ptr
    }
    
    deinit {
        thresholds.deallocate()
    }
    
    @inline(__always)
    func getValue(_ decoder: BinaryArithmeticDecoder) -> Int {
        var result = 0
        var index = 0
        var offset = 0
        for i in 0..<bitCount {
            let arrIdx = offset + index
            let threshold = thresholds[arrIdx]
            let bit = decoder.getBit(threshold: threshold)
            if bit == 0 {
                thresholds[arrIdx] = adjustThresholdUp(threshold)
            } else {
                thresholds[arrIdx] = adjustThresholdDown(threshold)
            }
            result = (result << 1) | bit
            index = (index << 1) | bit
            offset += (1 << i)
        }
        return result
    }
}

// MARK: - LSBFirstGetter

final class LSBFirstGetter {
    private let thresholds: UnsafeMutableBufferPointer<UInt32>
    private let bitCount: Int
    
    init(bitCount: Int) {
        self.bitCount = bitCount
        let total = (1 << bitCount) - 1
        let ptr = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: total)
        ptr.initialize(repeating: 0x400)
        self.thresholds = ptr
    }
    
    deinit {
        thresholds.deallocate()
    }
    
    @inline(__always)
    func getValue(_ decoder: BinaryArithmeticDecoder) -> Int {
        var value = 0
        var offset = 0
        for layer in 0..<bitCount {
            let arrIdx = offset + value
            let threshold = thresholds[arrIdx]
            let bit = decoder.getBit(threshold: threshold)
            if bit == 0 {
                thresholds[arrIdx] = adjustThresholdUp(threshold)
            } else {
                thresholds[arrIdx] = adjustThresholdDown(threshold)
            }
            value |= (bit << layer)
            offset += (1 << layer)
        }
        return value
    }
}

// MARK: - UnaryGetter

final class UnaryGetter {
    private let thresholds: UnsafeMutableBufferPointer<UInt32>
    private let maxVal: Int
    
    init(maxVal: Int) {
        self.maxVal = maxVal
        let ptr = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: maxVal)
        ptr.initialize(repeating: 0x400)
        self.thresholds = ptr
    }
    
    deinit {
        thresholds.deallocate()
    }
    
    @inline(__always)
    func getValue(_ decoder: BinaryArithmeticDecoder) -> Int {
        for i in 0..<maxVal {
            let threshold = thresholds[i]
            let bit = decoder.getBit(threshold: threshold)
            if bit == 0 {
                thresholds[i] = adjustThresholdUp(threshold)
                return i
            }
            thresholds[i] = adjustThresholdDown(threshold)
        }
        return maxVal
    }
}

// MARK: - LiteralGetter

final class LiteralGetter {
    private let thresholds: UnsafeMutableBufferPointer<UInt32>
    
    private static let noContextBase = 0
    private static let contextZeroBase = 255
    private static let contextOneBase = 510
    
    init() {
        let ptr = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: 765)
        ptr.initialize(repeating: 0x400)
        self.thresholds = ptr
    }
    
    deinit {
        thresholds.deallocate()
    }
    
    @inline(__always)
    func getValue(_ contextByte: Int?, _ decoder: BinaryArithmeticDecoder) -> Int {
        var bitval = 0
        var matched = true
        var offset = 0
        
        let hasContext = contextByte != nil
        let cb = contextByte ?? 0
        
        for bitnr in 0..<8 {
            let referenceBit = hasContext && (cb & (0x80 >> bitnr)) != 0
            
            let base: Int
            if matched && hasContext {
                base = referenceBit ? LiteralGetter.contextOneBase : LiteralGetter.contextZeroBase
            } else {
                base = LiteralGetter.noContextBase
            }
            
            let arrIdx = base + offset + bitval
            let threshold = thresholds[arrIdx]
            let bit = decoder.getBit(threshold: threshold)
            
            if bit == 0 {
                thresholds[arrIdx] = adjustThresholdUp(threshold)
            } else {
                thresholds[arrIdx] = adjustThresholdDown(threshold)
            }
            
            matched = matched && hasContext && (bit == (referenceBit ? 1 : 0))
            bitval = (bitval << 1) | bit
            offset += (1 << bitnr)
        }
        
        return bitval
    }
}

// MARK: - LengthGetter

final class LengthGetter {
    private var rangeGetter: UnaryGetter
    private var range0: (MSBFirstGetter, MSBFirstGetter, MSBFirstGetter, MSBFirstGetter)
    private var range1: (MSBFirstGetter, MSBFirstGetter, MSBFirstGetter, MSBFirstGetter)
    private var sharedLong: MSBFirstGetter
    
    init() {
        self.rangeGetter = UnaryGetter(maxVal: 2)
        self.range0 = (MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3))
        self.range1 = (MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3), MSBFirstGetter(bitCount: 3))
        self.sharedLong = MSBFirstGetter(bitCount: 8)
    }
    
    @inline(__always)
    func getValue(_ subctx: Int, _ decoder: BinaryArithmeticDecoder) -> Int {
        let rangeIndex = rangeGetter.getValue(decoder)
        let getter: MSBFirstGetter
        let base: Int
        
        if rangeIndex == 0 {
            base = 0
            getter = subctx == 0 ? range0.0 : subctx == 1 ? range0.1 : subctx == 2 ? range0.2 : range0.3
        } else if rangeIndex == 1 {
            base = 8
            getter = subctx == 0 ? range1.0 : subctx == 1 ? range1.1 : subctx == 2 ? range1.2 : range1.3
        } else {
            base = 16
            getter = sharedLong
        }
        
        return base + getter.getValue(decoder)
    }
}

// MARK: - DistanceGetter

final class DistanceGetter {
    private var coarse: (MSBFirstGetter, MSBFirstGetter, MSBFirstGetter, MSBFirstGetter)
    private var medium: ((LSBFirstGetter, LSBFirstGetter), (LSBFirstGetter, LSBFirstGetter), (LSBFirstGetter, LSBFirstGetter), (LSBFirstGetter, LSBFirstGetter), (LSBFirstGetter, LSBFirstGetter))
    private var longLow: LSBFirstGetter
    
    init() {
        self.coarse = (MSBFirstGetter(bitCount: 6), MSBFirstGetter(bitCount: 6), MSBFirstGetter(bitCount: 6), MSBFirstGetter(bitCount: 6))
        self.medium = (
            (LSBFirstGetter(bitCount: 1), LSBFirstGetter(bitCount: 1)),
            (LSBFirstGetter(bitCount: 2), LSBFirstGetter(bitCount: 2)),
            (LSBFirstGetter(bitCount: 3), LSBFirstGetter(bitCount: 3)),
            (LSBFirstGetter(bitCount: 4), LSBFirstGetter(bitCount: 4)),
            (LSBFirstGetter(bitCount: 5), LSBFirstGetter(bitCount: 5))
        )
        self.longLow = LSBFirstGetter(bitCount: 4)
    }
    
    @inline(__always)
    func getValue(_ lengthCode: Int, _ decoder: BinaryArithmeticDecoder) -> Int {
        let coarseIdx = min(lengthCode, 3)
        let coarseGetter = coarseIdx == 0 ? coarse.0 : coarseIdx == 1 ? coarse.1 : coarseIdx == 2 ? coarse.2 : coarse.3
        let coarseDist = coarseGetter.getValue(decoder)
        
        if coarseDist < 4 {
            return coarseDist
        }
        
        let nextToMSB = coarseDist & 1
        let extraBitsToFetch = 1 + ((coarseDist - 4) >> 1)
        let resultHigh = (2 | nextToMSB) << extraBitsToFetch
        
        if extraBitsToFetch < 6 {
            let mediumPair: (LSBFirstGetter, LSBFirstGetter)
            switch extraBitsToFetch {
            case 1: mediumPair = medium.0
            case 2: mediumPair = medium.1
            case 3: mediumPair = medium.2
            case 4: mediumPair = medium.3
            default: mediumPair = medium.4
            }
            
            let mediumGetter = nextToMSB == 0 ? mediumPair.0 : mediumPair.1
            let result = resultHigh | mediumGetter.getValue(decoder)
            return max(1, result)
        } else {
            var result = resultHigh
            for bitnum in stride(from: extraBitsToFetch - 1, through: 4, by: -1) {
                result |= decoder.getRawBit() << bitnum
            }
            let finalResult = result | longLow.getValue(decoder)
            return max(1, finalResult)
        }
    }
}

// MARK: - State

final class State {
    var afterLiteral: State!
    var getReferenceKind: UnaryGetter
    private let isReferenceCodeThresholds: UnsafeMutableBufferPointer<UInt32>
    private let getKind1NontrivialThresholds: UnsafeMutableBufferPointer<UInt32>
    
    init(stateAfterLiteral: State? = nil) {
        let ptr1 = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: 4)
        ptr1.initialize(repeating: 0x400)
        self.isReferenceCodeThresholds = ptr1
        
        let ptr2 = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: 4)
        ptr2.initialize(repeating: 0x400)
        self.getKind1NontrivialThresholds = ptr2
        
        self.getReferenceKind = UnaryGetter(maxVal: 4)
        self.afterLiteral = stateAfterLiteral ?? self
    }
    
    deinit {
        isReferenceCodeThresholds.deallocate()
        getKind1NontrivialThresholds.deallocate()
    }
    
    @inline(__always)
    func getIsReferenceCode(_ byteInDword: Int, _ decoder: BinaryArithmeticDecoder) -> Int {
        let threshold = isReferenceCodeThresholds[byteInDword]
        let bit = decoder.getBit(threshold: threshold)
        if bit == 0 {
            isReferenceCodeThresholds[byteInDword] = adjustThresholdUp(threshold)
        } else {
            isReferenceCodeThresholds[byteInDword] = adjustThresholdDown(threshold)
        }
        return bit
    }
    
    @inline(__always)
    func getKind1NontrivialBit(_ byteInDword: Int, _ decoder: BinaryArithmeticDecoder) -> Int {
        let threshold = getKind1NontrivialThresholds[byteInDword]
        let bit = decoder.getBit(threshold: threshold)
        if bit == 0 {
            getKind1NontrivialThresholds[byteInDword] = adjustThresholdUp(threshold)
        } else {
            getKind1NontrivialThresholds[byteInDword] = adjustThresholdDown(threshold)
        }
        return bit
    }
}

// MARK: - MRUList

final class MRUList {
    private var history: (Int, Int, Int, Int)
    
    init(length: Int) {
        self.history = (0, 0, 0, 0)
    }
    
    @inline(__always)
    func mru() -> Int {
        return history.0
    }
    
    @inline(__always)
    func addValue(_ newValue: Int) {
        history.3 = history.2
        history.2 = history.1
        history.1 = history.0
        history.0 = newValue
    }
    
    @inline(__always)
    func pickRecentlyUsed(at index: Int) -> Int {
        let picked: Int
        switch index {
        case 0:
            picked = history.0
        case 1:
            picked = history.1
            history.1 = history.0
            history.0 = picked
        case 2:
            picked = history.2
            history.2 = history.1
            history.1 = history.0
            history.0 = picked
        default:
            picked = history.3
            history.3 = history.2
            history.2 = history.1
            history.1 = history.0
            history.0 = picked
        }
        return picked
    }
}

// MARK: - LZ77Output

final class LZ77Output {
    private let decoded: UnsafeMutableBufferPointer<UInt8>
    private var length: Int = 0
    
    init(capacity: Int) {
        self.decoded = .allocate(capacity: capacity)
    }
    
    deinit {
        decoded.deallocate()
    }
    
    @inline(__always)
    func literalByte(_ value: Int) {
        decoded[length] = UInt8(truncatingIfNeeded: value)
        length &+= 1
    }
    
    @inline(__always)
    func copyBytes(_ distance: Int, _ copyLen: Int) {
        for _ in 0..<copyLen {
            decoded[length] = UInt8(getEarlierByte(distance) & 0xFF)
            length &+= 1
        }
    }
    
    @inline(__always)
    func getEarlierByte(_ distance: Int) -> Int {
        let index = length - distance - 1
        if index >= 0 && index < length {
            return Int(decoded[index])
        }
        return 0
    }
    
    @inline(__always)
    func getByteInDword() -> Int {
        return length & 3
    }
    
    func getData() -> [UInt8] {
        return Array(UnsafeBufferPointer(start: decoded.baseAddress, count: length))
    }
    
    @inline(__always)
    func getLength() -> Int {
        return length
    }
}

// MARK: - MischiefUnpacker

class MischiefUnpacker {
    static func unpack(byteInput: [UInt8]) -> [UInt8]? {
        guard byteInput.count >= 4 else {
            print("Unpacker: Input too short to extract output length")
            return nil
        }
        
        let outLength = Int(byteInput[0]) | (Int(byteInput[1]) << 8) |
        (Int(byteInput[2]) << 16) | (Int(byteInput[3]) << 24)
        
        let reportInterval = max(1, outLength / 20)
        var nextReport = reportInterval
        
        let compressedData: [UInt8]
        if byteInput.count > 5 {
            compressedData = Array(byteInput[5...])
        } else {
            compressedData = []
        }
        
        guard let decoder = BinaryArithmeticDecoder(byteInput: compressedData) else {
            return nil
        }
        
        let output = LZ77Output(capacity: outLength)
        
        let literalGetters = (0..<8).map { _ in LiteralGetter() }
        let newDistanceLengthGetter = LengthGetter()
        let reusedDistanceLengthGetter = LengthGetter()
        let distanceGetter = DistanceGetter()
        let distanceHistory = MRUList(length: 4)
        
        let baseState = State()
        let intermediateAfterNewDistance = State(stateAfterLiteral: State(stateAfterLiteral: baseState))
        let intermediateAfterReusedDistance = State(stateAfterLiteral: State(stateAfterLiteral: baseState))
        let intermediateAfterTrivialCopy = State(stateAfterLiteral: State(stateAfterLiteral: baseState))
        let statesAfterNewDistance = [
            State(stateAfterLiteral: intermediateAfterNewDistance),
            State(stateAfterLiteral: intermediateAfterNewDistance)
        ]
        let commonAfterReuseOrTrivialAfterRef = State(stateAfterLiteral: intermediateAfterReusedDistance)
        let statesAfterReusedDistance = [
            State(stateAfterLiteral: intermediateAfterReusedDistance),
            commonAfterReuseOrTrivialAfterRef
        ]
        let statesAfterTrivialCopy = [
            State(stateAfterLiteral: intermediateAfterTrivialCopy),
            commonAfterReuseOrTrivialAfterRef
        ]
        
        var lastWasReference = false
        var copyMismatchByte: Int? = nil
        var state = baseState
        
        while output.getLength() < outLength {
            let byteInDword = output.getByteInDword()
            let isReference = state.getIsReferenceCode(byteInDword, decoder)
            
            if isReference == 0 {
                let earlierByte = output.getEarlierByte(0)
                let literalGetter = literalGetters[earlierByte >> 5]
                let literalValue = literalGetter.getValue(copyMismatchByte, decoder)
                output.literalByte(literalValue)
                state = state.afterLiteral
                copyMismatchByte = nil
                lastWasReference = false
            } else {
                let referenceKind = state.getReferenceKind.getValue(decoder)
                let copyLen: Int
                let distance: Int
                
                if referenceKind == 0 {
                    copyLen = newDistanceLengthGetter.getValue(byteInDword, decoder) + 2
                    distance = distanceGetter.getValue(copyLen - 2, decoder)
                    distanceHistory.addValue(distance)
                    state = statesAfterNewDistance[lastWasReference ? 1 : 0]
                } else if referenceKind == 1 && state.getKind1NontrivialBit(byteInDword, decoder) == 0 {
                    copyLen = 1
                    distance = distanceHistory.mru()
                    state = statesAfterTrivialCopy[lastWasReference ? 1 : 0]
                } else {
                    copyLen = reusedDistanceLengthGetter.getValue(byteInDword, decoder) + 2
                    distance = distanceHistory.pickRecentlyUsed(at: referenceKind - 1)
                    state = statesAfterReusedDistance[lastWasReference ? 1 : 0]
                }
                
                if output.getLength() + copyLen > outLength {
                    return nil
                }
                
                output.copyBytes(distance, copyLen)
                copyMismatchByte = output.getEarlierByte(distance)
                lastWasReference = true
            }
            
            if output.getLength() >= nextReport {
                print("Unpacker: Progress \(output.getLength())/\(outLength) bytes")
                nextReport += reportInterval
            }
        }
        
        return output.getData()
    }
}

// MARK: - ArtFileHeader

class ArtFileHeader {
    let magic: UInt32
    let unknown1: UInt32
    let unknown2: UInt32
    let unknown3: UInt32
    let unknown4: UInt32
    let unknown5: UInt32
    let unknown6: UInt32
    let unknown7: UInt32
    let dataSize: UInt32
    let unknown9: UInt32
    
    init?(data: [UInt8]) {
        guard data.count >= 40 else {
            print("ArtFileHeader: Data too short, need at least 40 bytes, got \(data.count)")
            return nil
        }
        
        magic = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        unknown1 = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        unknown2 = UInt32(data[8]) | UInt32(data[9]) << 8 | UInt32(data[10]) << 16 | UInt32(data[11]) << 24
        unknown3 = UInt32(data[12]) | UInt32(data[13]) << 8 | UInt32(data[14]) << 16 | UInt32(data[15]) << 24
        unknown4 = UInt32(data[16]) | UInt32(data[17]) << 8 | UInt32(data[18]) << 16 | UInt32(data[19]) << 24
        unknown5 = UInt32(data[20]) | UInt32(data[21]) << 8 | UInt32(data[22]) << 16 | UInt32(data[23]) << 24
        unknown6 = UInt32(data[24]) | UInt32(data[25]) << 8 | UInt32(data[26]) << 16 | UInt32(data[27]) << 24
        unknown7 = UInt32(data[28]) | UInt32(data[29]) << 8 | UInt32(data[30]) << 16 | UInt32(data[31]) << 24
        dataSize = UInt32(data[32]) | UInt32(data[33]) << 8 | UInt32(data[34]) << 16 | UInt32(data[35]) << 24
        unknown9 = UInt32(data[36]) | UInt32(data[37]) << 8 | UInt32(data[38]) << 16 | UInt32(data[39]) << 24
        
        guard magic == 0xc5b38be9 || magic == 0xc5b38be7 else {
            print("ArtFileHeader: Invalid magic number 0x\(String(magic, radix: 16))")
            return nil
        }
    }
}
