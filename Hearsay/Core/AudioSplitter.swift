import Foundation
import os.log

private let splitterLogger = Logger(subsystem: "com.swair.hearsay", category: "splitter")

/// Utility to split WAV audio files at specific timestamps
enum AudioSplitter {
    
    /// Split a WAV file at the given timestamps
    /// Returns URLs to the split segments (count = timestamps.count + 1)
    /// For example, if timestamps = [5.0, 10.0], returns 3 segments:
    ///   - 0 to 5 seconds
    ///   - 5 to 10 seconds
    ///   - 10 to end
    static func splitWAV(at url: URL, timestamps: [TimeInterval]) -> [URL]? {
        guard !timestamps.isEmpty else {
            // No splits needed, return original
            return [url]
        }
        
        guard let data = try? Data(contentsOf: url) else {
            splitterLogger.error("Failed to read WAV file: \(url.path)")
            return nil
        }
        
        // Parse WAV header
        guard data.count > 44 else {
            splitterLogger.error("WAV file too small")
            return nil
        }
        
        // Log first 64 bytes of file for debugging
        let headerBytes = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
        splitterLogger.info("WAV header bytes: \(headerBytes)")
        
        // Verify RIFF header
        let riffHeader = String(data: data[0..<4], encoding: .ascii)
        splitterLogger.info("RIFF header: '\(riffHeader ?? "nil")'")
        guard riffHeader == "RIFF" else {
            splitterLogger.error("Not a valid WAV file (missing RIFF header)")
            return nil
        }
        
        // Check WAVE format marker at bytes 8-11
        let waveMarker = String(data: data[8..<12], encoding: .ascii)
        splitterLogger.info("WAVE marker: '\(waveMarker ?? "nil")'")
        
        // Parse WAV chunks to find fmt and data
        var numChannels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataOffset = 0
        var dataSize = 0
        
        var chunkOffset = 12  // Skip RIFF header (4) + size (4) + WAVE (4)
        
        while chunkOffset < data.count - 8 {
            let chunkID = String(data: data[chunkOffset..<(chunkOffset + 4)], encoding: .ascii)
            let chunkSize = Int(data[chunkOffset + 4]) | (Int(data[chunkOffset + 5]) << 8) |
                           (Int(data[chunkOffset + 6]) << 16) | (Int(data[chunkOffset + 7]) << 24)
            
            splitterLogger.info("Found chunk '\(chunkID ?? "nil")' at \(chunkOffset), size \(chunkSize)")
            
            if chunkID == "fmt " {
                // Parse format chunk
                let fmtStart = chunkOffset + 8
                if fmtStart + 16 <= data.count {
                    // Audio format (2 bytes) - skip
                    numChannels = UInt16(data[fmtStart + 2]) | (UInt16(data[fmtStart + 3]) << 8)
                    sampleRate = UInt32(data[fmtStart + 4]) | (UInt32(data[fmtStart + 5]) << 8) |
                                (UInt32(data[fmtStart + 6]) << 16) | (UInt32(data[fmtStart + 7]) << 24)
                    // Byte rate (4 bytes) - skip
                    // Block align (2 bytes) - skip
                    bitsPerSample = UInt16(data[fmtStart + 14]) | (UInt16(data[fmtStart + 15]) << 8)
                }
            } else if chunkID == "data" {
                dataOffset = chunkOffset + 8  // Move past chunk header to actual data
                dataSize = chunkSize
                break
            }
            
            // Move to next chunk (chunks are word-aligned)
            let nextOffset = chunkOffset + 8 + chunkSize
            chunkOffset = nextOffset + (nextOffset % 2)  // Word align
        }
        
        let bytesPerSample = Int(numChannels) * Int(bitsPerSample) / 8
        let bytesPerSecond = Int(sampleRate) * bytesPerSample
        
        splitterLogger.info("WAV format: \(sampleRate)Hz, \(numChannels)ch, \(bitsPerSample)bit, \(bytesPerSecond) bytes/sec")
        
        // Safety check for invalid format
        guard bytesPerSample > 0 && bytesPerSecond > 0 else {
            splitterLogger.error("Invalid WAV format: bytesPerSample=\(bytesPerSample), bytesPerSecond=\(bytesPerSecond)")
            return nil
        }
        
        guard dataSize > 0 else {
            splitterLogger.error("Could not find data chunk in WAV file")
            return nil
        }
        
        splitterLogger.info("Data chunk at offset \(dataOffset), size \(dataSize) bytes")
        
        // Calculate byte offsets for each timestamp
        let sortedTimestamps = timestamps.sorted()
        var splitPoints: [Int] = []
        
        for timestamp in sortedTimestamps {
            let byteOffset = Int(timestamp * Double(bytesPerSecond))
            // Align to sample boundary
            let alignedOffset = (byteOffset / bytesPerSample) * bytesPerSample
            splitPoints.append(min(alignedOffset, dataSize))
        }
        
        splitterLogger.info("Split points (bytes): \(splitPoints)")
        
        // Create segments
        var segments: [URL] = []
        var previousOffset = 0
        
        // Validate dataOffset is within bounds
        guard dataOffset <= data.count else {
            splitterLogger.error("Data offset \(dataOffset) exceeds file size \(data.count)")
            return nil
        }
        
        // Header template (everything before the audio data)
        let headerTemplate = Data(data[0..<dataOffset])
        
        for (index, splitPoint) in (splitPoints + [dataSize]).enumerated() {
            let segmentDataSize = splitPoint - previousOffset
            
            guard segmentDataSize > 0 else {
                previousOffset = splitPoint
                continue
            }
            
            // Create segment file
            let segmentURL = url.deletingPathExtension()
                .appendingPathExtension("segment\(index)")
                .appendingPathExtension("wav")
            
            var segmentData = Data()
            
            // Write header with updated sizes
            var header = headerTemplate
            
            // Update RIFF chunk size (file size - 8)
            let riffSize = UInt32(header.count - 8 + segmentDataSize)
            header[4] = UInt8(riffSize & 0xFF)
            header[5] = UInt8((riffSize >> 8) & 0xFF)
            header[6] = UInt8((riffSize >> 16) & 0xFF)
            header[7] = UInt8((riffSize >> 24) & 0xFF)
            
            // Update data chunk size (last 4 bytes before data)
            let dataChunkSizeOffset = dataOffset - 4
            header[dataChunkSizeOffset] = UInt8(segmentDataSize & 0xFF)
            header[dataChunkSizeOffset + 1] = UInt8((segmentDataSize >> 8) & 0xFF)
            header[dataChunkSizeOffset + 2] = UInt8((segmentDataSize >> 16) & 0xFF)
            header[dataChunkSizeOffset + 3] = UInt8((segmentDataSize >> 24) & 0xFF)
            
            segmentData.append(header)
            
            // Append audio data with bounds checking
            let startByte = dataOffset + previousOffset
            let endByte = min(dataOffset + splitPoint, data.count)
            
            guard startByte < endByte && endByte <= data.count else {
                splitterLogger.error("Invalid segment bounds: start=\(startByte), end=\(endByte), dataCount=\(data.count)")
                previousOffset = splitPoint
                continue
            }
            
            segmentData.append(data[startByte..<endByte])
            
            do {
                try segmentData.write(to: segmentURL)
                segments.append(segmentURL)
                splitterLogger.info("Created segment \(index): \(segmentURL.lastPathComponent) (\(segmentDataSize) bytes)")
            } catch {
                splitterLogger.error("Failed to write segment \(index): \(error.localizedDescription)")
            }
            
            previousOffset = splitPoint
        }
        
        return segments.isEmpty ? nil : segments
    }
    
    /// Clean up segment files
    static func cleanupSegments(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            try? fm.removeItem(at: url)
        }
    }
}
