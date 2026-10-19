import Foundation
import Compression

// UYAP .udf belgesini biçimli HTML'e çevirir (antet, kalın/italik/altı çizili, hizalama, sekmeler, tablolar).
// .udf bir zip paketidir; içindeki content.xml metni tek parça tutar, biçim öğeleri metne konumla bağlanır.

enum UDFHata: Error { case paketDegil, icerikYok, xmlBozuk }

/// Zip paketinden adı verilen dosyayı okur (yalnızca saklanmış ve deflate sıkıştırılmış girdiler).
func zipOku(_ d: Data, _ ad: String) -> Data? {
    let b = [UInt8](d)
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    guard b.count > 22 else { return nil }
    if let d = merkezdenOku(b, ad) { return d }
    return yereldenOku(b, ad)
}

/// Normal yol: zip'in sonundaki merkez dizininden.
func merkezdenOku(_ b: [UInt8], _ ad: String) -> Data? {
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    var son = -1
    for o in stride(from: b.count - 22, through: max(0, b.count - 22 - 65535), by: -1)
        where b[o] == 0x50 && b[o + 1] == 0x4b && b[o + 2] == 5 && b[o + 3] == 6 { son = o; break }
    guard son >= 0 else { return nil }
    var o = u32(son + 16)
    for _ in 0..<u16(son + 10) {
        guard o + 46 <= b.count, u32(o) == 0x02014b50 else { return nil }
        let yontem = u16(o + 10), sikisik = u32(o + 20), acik = u32(o + 24)
        let n = u16(o + 28), ek = u16(o + 30), yorum = u16(o + 32), yerel = u32(o + 42)
        let isim = String(decoding: b[(o + 46)..<(o + 46 + n)], as: UTF8.self)
        if isim == ad || isim.hasSuffix("/" + ad) {
            guard yerel + 30 <= b.count else { return nil }
            let bas = yerel + 30 + u16(yerel + 26) + u16(yerel + 28)
            guard bas + sikisik <= b.count else { return nil }
            let veri = Array(b[bas..<(bas + sikisik)])
            if yontem == 0 { return Data(veri) }
            guard yontem == 8 else { return nil }
            guard let c = inflate(veri), c.count == acik else { return nil }
            return c
        }
        o += 46 + n + ek + yorum
    }
    return nil
}

/// Yedek yol: merkez dizini yazılmamış (yarım kaydedilmiş) paketlerde yerel başlığı arar.
func yereldenOku(_ b: [UInt8], _ ad: String) -> Data? {
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    var o = 0
    while o + 30 <= b.count {
        guard b[o] == 0x50, b[o + 1] == 0x4b, b[o + 2] == 3, b[o + 3] == 4 else { o += 1; continue }
        let yontem = u16(o + 8), n = u16(o + 26), ek = u16(o + 28)
        guard o + 30 + n <= b.count else { return nil }
        let isim = String(decoding: b[(o + 30)..<(o + 30 + n)], as: UTF8.self)
        let bas = o + 30 + n + ek
        if isim == ad || isim.hasSuffix("/" + ad), bas < b.count {
            let veri = Array(b[bas...])
            return yontem == 8 ? inflate(veri) : nil
        }
        o = bas
    }
    return nil
}

/// Ham deflate akışını açar; akış bitince durur (boyutu bilinmese de).
func inflate(_ girdi: [UInt8]) -> Data? {
    let tampon = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
    defer { tampon.deallocate() }
    let akis = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { akis.deallocate() }
    guard compression_stream_init(akis, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
    defer { compression_stream_destroy(akis) }
    var cikti = Data()
    return girdi.withUnsafeBufferPointer { g -> Data? in
        akis.pointee.src_ptr = g.baseAddress!
        akis.pointee.src_size = g.count
        while true {
            akis.pointee.dst_ptr = tampon
            akis.pointee.dst_size = 65536
            let durum = compression_stream_process(akis, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            cikti.append(tampon, count: 65536 - akis.pointee.dst_size)
            if durum == COMPRESSION_STATUS_END { return cikti }
            if durum != COMPRESSION_STATUS_OK || (akis.pointee.src_size == 0 && akis.pointee.dst_size > 0) {
                return cikti.isEmpty ? nil : cikti
            }
        }
    }
}

func kacis(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func sayi(_ s: String?) -> Double? { s.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
func pt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

struct UDFBelge {
    let metin: NSString
    var stiller: [String: [String: String]] = [:]
    /// Form şablonlu evrakta (talep, haciz vb.) alanların asıl değerleri <data> bölümündedir.
    var alanlar: [String: String] = [:]

    func stil(_ e: XMLElement) -> [String: String] {
        var h: [String: String] = [:]
        if let r = e.attribute(forName: "resolver")?.stringValue, let s = stiller[r] { h = s }
        for a in e.attributes ?? [] { if let n = a.name, let v = a.stringValue { h[n] = v } }
        return h
    }

    func paragraf(_ p: XMLElement) -> String {
        let ps = stil(p)
        let hiza = ["1": "center", "2": "right", "3": "justify"][ps["Alignment"] ?? ""] ?? "left"
        let tab = ps["TabSet"].flatMap { sayi(String($0.split(separator: ":").first ?? "")) } ?? 36
        var css = "text-align:\(hiza);tab-size:\(pt(tab))pt;"
        for (k, ozellik) in [("LeftIndent", "margin-left"), ("RightIndent", "margin-right"),
                             ("SpaceAbove", "margin-top"), ("SpaceBelow", "margin-bottom"),
                             ("FirstLineIndent", "text-indent")] {
            if let v = sayi(ps[k]) { css += "\(ozellik):\(pt(v))pt;" }
        }
        var parcalar = ""
        for c in p.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if c.name == "image" {
                let b64 = (c.attribute(forName: "imageData")?.stringValue ?? "").filter { !$0.isWhitespace }
                guard !b64.isEmpty else { continue }
                let tur = b64.hasPrefix("/9j") ? "image/jpeg" : b64.hasPrefix("R0lG") ? "image/gif" : "image/png"
                parcalar += "<img src=\"data:\(tur);base64,\(b64)\">"
                continue
            }
            let cs = stil(c)
            let bas = Int(c.attribute(forName: "startOffset")?.stringValue ?? "") ?? 0
            let uzun = Int(c.attribute(forName: "length")?.stringValue ?? "") ?? 0
            guard bas >= 0, uzun > 0, bas + uzun <= metin.length else { continue }
            var t = metin.substring(with: NSRange(location: bas, length: uzun))
                .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            if c.name == "field", let ad = c.attribute(forName: "fieldName")?.stringValue, let v = alanlar[ad] {
                t = v.replacingOccurrences(of: "\r", with: "")   // alan değerindeki satır sonları korunur
            }
            guard !t.isEmpty else { continue }
            var rs = ""
            if cs["bold"] == "true" { rs += "font-weight:bold;" }
            if cs["italic"] == "true" { rs += "font-style:italic;" }
            if cs["underline"] == "true" { rs += "text-decoration:underline;" }
            if let s = sayi(cs["size"]) { rs += "font-size:\(pt(s))pt;" }
            if let f = cs["family"], f != "Dialog", f != "Editor" { rs += "font-family:'\(kacis(f))',serif;" }
            parcalar += "<span style=\"\(rs)\">\(kacis(t))</span>"
        }
        return "<p style=\"\(css)\">\(parcalar.isEmpty ? "&nbsp;" : parcalar)</p>"
    }

    func blok(_ dugum: XMLElement?) -> String {
        var cikti: [String] = []
        for c in dugum?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if c.name == "paragraph" { cikti.append(paragraf(c)) }
            else if c.name == "table" {
                let kenar = c.attribute(forName: "border")?.stringValue == "borderNone" ? "none" : "1px solid #000"
                cikti.append("<table>")
                for satir in c.elements(forName: "row") {
                    let hucreler = satir.elements(forName: "cell")
                        .map { "<td style=\"border:\(kenar)\">\(blok($0))</td>" }.joined()
                    cikti.append("<tr>\(hucreler)</tr>")
                }
                cikti.append("</table>")
            }
            // header (2. sayfadan itibaren tekrarlanan başlık) ve footer (sayfa no) gösterilmez
        }
        return cikti.joined(separator: "\n")
    }
}

/// .udf dosyasını ekranda kâğıt görünümünde gösterilecek tam bir HTML belgesine çevirir.
func udfHTML(_ veri: Data, baslik: String) throws -> String {
    let xml: Data
    if veri.count > 4, veri[0] == 0x50, veri[1] == 0x4b {
        guard let x = zipOku(veri, "content.xml") else { throw UDFHata.icerikYok }
        xml = x
    } else if veri.prefix(64).contains(UInt8(ascii: "<")) {
        xml = veri   // bazı evraklar zip'lenmemiş düz content.xml olarak kaydedilmiş
    } else { throw UDFHata.paketDegil }
    guard let doc = try? XMLDocument(data: xml, options: []), let kok = doc.rootElement() else { throw UDFHata.xmlBozuk }
    let metin = kok.elements(forName: "content").first?.stringValue ?? ""
    var belge = UDFBelge(metin: metin as NSString)
    for e in kok.elements(forName: "styles").first?.elements(forName: "style") ?? [] {
        guard let ad = e.attribute(forName: "name")?.stringValue else { continue }
        var h: [String: String] = [:]
        for a in e.attributes ?? [] where a.name != "name" { if let n = a.name, let v = a.stringValue { h[n] = v } }
        belge.stiller[ad] = h
    }
    for e in kok.elements(forName: "data").first?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
        guard let ad = e.name, let v = e.stringValue,
              !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, belge.alanlar[ad] == nil else { continue }
        belge.alanlar[ad] = v.trimmingCharacters(in: .newlines)
    }
    let pf = kok.elements(forName: "properties").first?.elements(forName: "pageFormat").first
    let kenar = ["topMargin", "rightMargin", "bottomMargin", "leftMargin"].map { k -> String in
        let v = sayi(pf?.attribute(forName: k)?.stringValue) ?? 42.5
        return pt(max(v, 28)) + "pt"
    }.joined(separator: " ")
    let govde = belge.blok(kok.elements(forName: "elements").first)
    return """
    <!DOCTYPE html><html lang="tr"><head><meta charset="utf-8"><title>\(kacis(baslik))</title><style>
    html { background: #8e8e93; }
    body { margin: 0; padding: 24px 0; }
    .sayfa { width: 595pt; min-height: 842pt; box-sizing: border-box; margin: 0 auto; padding: \(kenar);
             background: #fff; color: #000; box-shadow: 0 2px 10px rgba(0,0,0,.35);
             font-family: 'Times New Roman', serif; font-size: 12pt; }
    p { margin: 0; white-space: pre-wrap; line-height: 1.2; }
    img { max-height: 40pt; vertical-align: middle; }
    table { width: 100%; border-collapse: collapse; }
    td { vertical-align: top; }
    td p { margin-left: 3pt; margin-right: 1pt; }
    </style></head><body><div class="sayfa">
    \(govde)
    </div></body></html>
    """
}

/// Çevrilemeyen paketler için kısa açıklama sayfası.
func hataHTML(_ h: Error, baslik: String) -> String {
    let neden: String
    switch h {
    case UDFHata.icerikYok: neden = "Pakette content.xml yok; e-imzalı ya da farklı biçimde bir paket olabilir."
    case UDFHata.paketDegil: neden = "Dosya bir UDF paketi gibi görünmüyor."
    default: neden = "Belgenin içeriği okunamadı."
    }
    return """
    <!DOCTYPE html><html lang="tr"><head><meta charset="utf-8"><style>
    body { font: 15px -apple-system, sans-serif; padding: 40px; color: #222; }
    </style></head><body><h3>\(kacis(baslik))</h3><p>\(kacis(neden))</p>
    <p>Belgeyi UYAP Doküman Editörü ile açabilirsiniz.</p></body></html>
    """
}
