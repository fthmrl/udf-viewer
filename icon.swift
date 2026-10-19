import AppKit
// UDF Viewer simgesi: TIFF Viewer ile aynı siyah-beyaz 8-bit tarz: 32x32 piksel ızgarası her boyuta keskin kenarlı büyütülür
// 32x32 piksel ızgara: 0 boş, 1 siyah, 2 beyaz
var g = Array(repeating: Array(repeating: 0, count: 32), count: 32)
func inRounded(_ x: Int, _ y: Int, _ lo: Int, _ hi: Int, _ r: Double) -> Bool {
    if x < lo || x > hi || y < lo || y > hi { return false }
    let cx = Double(min(max(x, lo + Int(r)), hi - Int(r))), cy = Double(min(max(y, lo + Int(r)), hi - Int(r)))
    let dx = Double(x) - cx, dy = Double(y) - cy
    return dx * dx + dy * dy <= (r + 0.5) * (r + 0.5)
}
for y in 0..<32 { for x in 0..<32 where inRounded(x, y, 3, 28, 6) { g[y][x] = 1 } }
// Belge sayfası, sağ üstte kıvrık köşe
for y in 5...26 { for x in 6...21 { g[y][x] = 2 } }
for y in 5...7 { for x in 19...21 where (x - 19) > (y - 5) { g[y][x] = 1 } }
for i in 0...2 { g[5 + i][19 + i] = 1 }
g[7][19] = 1; g[7][20] = 1
// UDF yazısı (3x5 piksel font)
let U = ["101","101","101","101","111"], D = ["110","101","101","101","110"], F = ["111","100","110","100","100"]
for (glyph, x0) in [(U, 8), (D, 12), (F, 16)] {
    for (r, row) in glyph.enumerated() { for (c, ch) in row.enumerated() where ch == "1" { g[10 + r][x0 + c] = 1 } }
}
// Metin satırları
for (i, y) in [18, 20, 22, 24].enumerated() { for x in 8...(i % 2 == 0 ? 18 : 15) { g[y][x] = 1 } }
// Büyüteç
let cx = 21.5, cy = 21.5
for y in 0..<32 { for x in 0..<32 {
    let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
    if d <= 2.7 { g[y][x] = 2 }   // cam
    else if d <= 3.7 { g[y][x] = 1 }
    else if d <= 5.0 { g[y][x] = 2 }
    else if d <= 6.0 { g[y][x] = 1 }
}}
for (x, y) in [(20, 20), (21, 20), (20, 21)] { g[y][x] = 1 }   // parıltı (piksel)
// Sap
for y in 0..<32 { for x in 0..<32 {
    let s = x + y, k = abs(x - y)
    if s >= 50 && s <= 56 { if k <= 1 { g[y][x] = 2 } else if k == 2 { g[y][x] = 1 } }
    if s == 57 && k <= 2 { g[y][x] = 1 }
}}
func render(_ px: Int, _ path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = CGFloat(px) / 32
    for y in 0..<32 { for x in 0..<32 where g[y][x] != 0 {
        (g[y][x] == 1 ? NSColor.black : NSColor.white).setFill()
        NSRect(x: CGFloat(x) * c, y: CGFloat(31 - y) * c, width: c, height: c).fill()
    }}
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
// Simge setini üretir:  swift icon.swift  →  AppIcon.iconset + simge.png (README), sonra: iconutil -c icns AppIcon.iconset
try? FileManager.default.createDirectory(atPath: "AppIcon.iconset", withIntermediateDirectories: true)
for n in [16, 32, 128, 256, 512] {
    render(n, "AppIcon.iconset/icon_\(n)x\(n).png")
    render(n * 2, "AppIcon.iconset/icon_\(n)x\(n)@2x.png")
}
render(256, "simge.png")
