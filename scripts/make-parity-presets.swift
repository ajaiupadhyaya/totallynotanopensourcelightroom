#!/usr/bin/env swift
// Emits the Lightroom XMP preset set + manifest for the parity harness.
// Output: scripts/parity-presets/*.xmp and Tests/Fixtures/Parity/manifest.json
//
// Path resolution note: `#filePath` in Swift's script mode expands to
// whatever path string was passed to the `swift` invocation, not a
// canonicalized absolute path. Run this as `swift scripts/make-parity-presets.swift`
// from the repository root — `URL(fileURLWithPath:)` then resolves that
// relative path against the current working directory, landing `root` on
// `<repo>/scripts` exactly as intended. Running it from any other directory
// (or via a symlink) will place output relative to that directory instead.
import Foundation

struct Preset {
    let name: String          // also the fixture filename stem
    let crsKey: String
    let crsValue: String
    let field: String         // EditStack field
    let value: Double
    let meanTol: Double?      // nil = report-only
    let maxTol: Double?
}

// Sliders whose −100…100 semantics map 1:1 map with strict tolerances;
// WB on a rendered file uses Lightroom's incremental units, which have no
// exact mapping to Kelvin — those are report-only.
let presets: [Preset] = [
    .init(name: "exposure_p1", crsKey: "crs:Exposure2012", crsValue: "+1.00", field: "exposure", value: 1, meanTol: 6, maxTol: 14),
    .init(name: "exposure_m1", crsKey: "crs:Exposure2012", crsValue: "-1.00", field: "exposure", value: -1, meanTol: 6, maxTol: 14),
    .init(name: "contrast_p50", crsKey: "crs:Contrast2012", crsValue: "+50", field: "contrast", value: 50, meanTol: 6, maxTol: 14),
    .init(name: "contrast_m50", crsKey: "crs:Contrast2012", crsValue: "-50", field: "contrast", value: -50, meanTol: 6, maxTol: 14),
    .init(name: "contrast_p100", crsKey: "crs:Contrast2012", crsValue: "+100", field: "contrast", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "highlights_m100", crsKey: "crs:Highlights2012", crsValue: "-100", field: "highlights", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "highlights_p100", crsKey: "crs:Highlights2012", crsValue: "+100", field: "highlights", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "shadows_p100", crsKey: "crs:Shadows2012", crsValue: "+100", field: "shadows", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "shadows_m100", crsKey: "crs:Shadows2012", crsValue: "-100", field: "shadows", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "whites_p100", crsKey: "crs:Whites2012", crsValue: "+100", field: "whites", value: 100, meanTol: 8, maxTol: 18),
    .init(name: "blacks_m100", crsKey: "crs:Blacks2012", crsValue: "-100", field: "blacks", value: -100, meanTol: 8, maxTol: 18),
    .init(name: "vibrance_p60", crsKey: "crs:Vibrance", crsValue: "+60", field: "vibrance", value: 60, meanTol: 7, maxTol: 16),
    .init(name: "saturation_p50", crsKey: "crs:Saturation", crsValue: "+50", field: "saturation", value: 50, meanTol: 7, maxTol: 16),
    .init(name: "saturation_m50", crsKey: "crs:Saturation", crsValue: "-50", field: "saturation", value: -50, meanTol: 7, maxTol: 16),
    .init(name: "temp_p40", crsKey: "crs:IncrementalTemperature", crsValue: "+40", field: "whiteBalanceTemp", value: 8000, meanTol: nil, maxTol: nil),
    .init(name: "temp_m40", crsKey: "crs:IncrementalTemperature", crsValue: "-40", field: "whiteBalanceTemp", value: 5000, meanTol: nil, maxTol: nil),
    .init(name: "tint_p50", crsKey: "crs:IncrementalTint", crsValue: "+50", field: "whiteBalanceTint", value: 50, meanTol: nil, maxTol: nil),
]

func xmp(_ p: Preset) -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PV2 parity generator">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        crs:PresetType="Normal"
        crs:Cluster="PV2 Parity"
        crs:UUID="\(UUID().uuidString)"
        crs:SupportsAmount="False"
        crs:SupportsColor="True"
        crs:SupportsMonochrome="True"
        crs:ProcessVersion="15.4"
        \(p.crsKey)="\(p.crsValue)"
        crs:HasSettings="True">
       <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">PV2 \(p.name)</rdf:li></rdf:Alt></crs:Name>
       <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">PV2 Parity</rdf:li></rdf:Alt></crs:Group>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outDir = root.appendingPathComponent("parity-presets")
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
for p in presets {
    try! xmp(p).write(to: outDir.appendingPathComponent("PV2_\(p.name).xmp"),
                      atomically: true, encoding: .utf8)
}
struct ManifestEntry: Encodable {
    let fixture: String, field: String, value: Double
    let meanTolerance: Double?, maxTolerance: Double?
}
let manifest = presets.map {
    ManifestEntry(fixture: "\($0.name).tif", field: $0.field, value: $0.value,
                  meanTolerance: $0.meanTol, maxTolerance: $0.maxTol)
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
let manifestDir = root.deletingLastPathComponent()
    .appendingPathComponent("Tests/Fixtures/Parity")
try? fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
// Trailing newline: this file is tracked, and JSONEncoder does not add one.
var manifestData = try! enc.encode(manifest)
manifestData.append(0x0A)
try manifestData.write(to: manifestDir.appendingPathComponent("manifest.json"))
print("Wrote \(presets.count) presets to \(outDir.path) and manifest.json")
