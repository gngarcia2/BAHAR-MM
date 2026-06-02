//
//  FloodData.swift
//  BAHAR QC
//
//  Swift port of the JS FloodData loader. Reads a uint16-LE binary grid plus
//  its JSON header and answers depth-at-coordinate queries with bilinear
//  interpolation, matching the prototype's behaviour.
//

import Foundation

/// Classification of flood depth using the MMDA Flood Gauge System
/// (PATV / NPLV / NPATV) plus the descriptive sub-label motorists recognise.
nonisolated struct MMDAGauge: Equatable, Sendable {
    enum Category: String, Sendable {
        case none, patv, nplv, npatv

        var abbreviation: String {
            switch self {
            case .none: return ""
            case .patv: return "PATV"
            case .nplv: return "NPLV"
            case .npatv: return "NPATV"
            }
        }

        var fullName: String {
            switch self {
            case .none:  return "NO FLOOD IN THIS AREA"
            case .patv:  return "PASSABLE TO ALL TYPES OF VEHICLES"
            case .nplv:  return "NOT PASSABLE TO LIGHT VEHICLES"
            case .npatv: return "NOT PASSABLE TO ALL TYPES OF VEHICLES"
            }
        }
    }

    let category: Category
    let description: String

    static let none = MMDAGauge(category: .none, description: "")

    /// Maps a depth in metres to its MMDA gauge classification. Thresholds are
    /// the inch markers from the official system (8, 10, 13, 19, 26, 37, 45).
    static func from(depthMeters: Double) -> MMDAGauge {
        guard depthMeters > 0 else { return .none }
        let inches = depthMeters * 39.3700787

        if inches < 10  { return MMDAGauge(category: .patv,  description: "Gutter deep flood") }
        if inches < 13  { return MMDAGauge(category: .patv,  description: "Half-knee deep flood") }
        if inches < 19  { return MMDAGauge(category: .nplv,  description: "Half tire deep flood") }
        if inches < 26  { return MMDAGauge(category: .nplv,  description: "Knee deep flood") }
        if inches < 37  { return MMDAGauge(category: .npatv, description: "Tire deep flood") }
        if inches < 45  { return MMDAGauge(category: .npatv, description: "Waist deep flood") }
        return MMDAGauge(category: .npatv, description: "Chest deep flood")
    }
}

nonisolated struct FloodHeader: Decodable, Sendable {
    nonisolated struct Bounds: Decodable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
    }
    let bounds: Bounds
    let cols: Int
    let rows: Int
    let cellDeg: Double
    let step: Double
    let dataFile: String
}

actor FloodData {
    private var header: FloodHeader?
    private var binData: Data = Data()

    var isReady: Bool { header != nil }

    func load(headerName: String = "qc_flood_header", binaryName: String = "qc_flood") throws {
        guard let headerURL = Bundle.main.url(forResource: headerName, withExtension: "json") else {
            throw LoadError.missingResource(headerName + ".json")
        }
        let headerData = try Data(contentsOf: headerURL)
        let hdr = try JSONDecoder().decode(FloodHeader.self, from: headerData)

        guard let binURL = Bundle.main.url(forResource: binaryName, withExtension: "bin") else {
            throw LoadError.missingResource(hdr.dataFile)
        }
        // Memory-map the 38 MB grid instead of copying it into an array — load
        // is now near-instant and uses zero extra heap.
        let data = try Data(contentsOf: binURL, options: .mappedIfSafe)
        let expected = hdr.cols * hdr.rows * MemoryLayout<UInt16>.size
        guard data.count >= expected else {
            throw LoadError.shortRead(have: data.count, want: expected)
        }

        self.header = hdr
        self.binData = data
    }

    /// Returns flood depth in metres at the given WGS-84 coordinate.
    /// `nil` = outside the data extent, 0 = inside extent / no flood modelled.
    func depth(latitude lat: Double, longitude lon: Double) -> Double? {
        guard let hdr = header else { return nil }
        let b = hdr.bounds
        guard lon >= b.west, lon <= b.east, lat >= b.south, lat <= b.north else { return nil }

        let fc = (lon - b.west)  / hdr.cellDeg
        let fr = (b.north - lat) / hdr.cellDeg

        let col0 = min(Int(fc.rounded(.down)), hdr.cols - 1)
        let row0 = min(Int(fr.rounded(.down)), hdr.rows - 1)
        let fx = fc - Double(col0)
        let fy = fr - Double(row0)

        let q00 = cell(row: row0, col: col0, hdr: hdr)
        if q00 == 0 { return 0 }

        let q10 = cell(row: row0,     col: col0 + 1, hdr: hdr)
        let q01 = cell(row: row0 + 1, col: col0,     hdr: hdr)
        let q11 = cell(row: row0 + 1, col: col0 + 1, hdr: hdr)

        let q = (1 - fy) * ((1 - fx) * Double(q00) + fx * Double(q10))
              +      fy  * ((1 - fx) * Double(q01) + fx * Double(q11))
        guard q > 0 else { return 0 }
        return (q * hdr.step * 100).rounded() / 100
    }

    func gauge(for depth: Double) -> MMDAGauge {
        MMDAGauge.from(depthMeters: depth)
    }

    private func cell(row: Int, col: Int, hdr: FloodHeader) -> UInt16 {
        guard row >= 0, row < hdr.rows, col >= 0, col < hdr.cols else { return 0 }
        let offset = (row * hdr.cols + col) * MemoryLayout<UInt16>.size
        return binData.withUnsafeBytes { raw -> UInt16 in
            let ptr = raw.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: UInt16.self)
            return UInt16(littleEndian: ptr.pointee)
        }
    }

    enum LoadError: Error, LocalizedError {
        case missingResource(String)
        case shortRead(have: Int, want: Int)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Flood data resource \(name) not found in app bundle."
            case .shortRead(let have, let want):
                return "Flood binary truncated: \(have) bytes, expected \(want)."
            }
        }
    }
}
