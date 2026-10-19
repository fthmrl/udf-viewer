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

// Form şablonlu evrakta (takip/haciz/tebligat talebi vb.) metinde yalnızca alan adı yazar; asıl değerler
// content.xml sonundaki <data> bölümündedir. Alanlar gruplara bağlıdır (fieldGroupName): verisinde
// bulunmayan grubun alanları ve yazıları gösterilmez (ör. "vekilleri", mirasçı, ilam bilgisi). Satırı
// "dataRow" olan tablolar verideki her satır için tekrarlanır. Verideki adlarda rakamlar X+harf
// yazılır (Tablo40 -> TabloXeXa). Normal dilekçede <data> yoktur; metin olduğu gibi gösterilir.
// (evrak-isleme/scripts/yazdir.py ile aynı kurallar)
func kod(_ ad: String) -> String {
    var s = ""
    for ch in ad {
        if ch.isASCII, let d = ch.wholeNumberValue { s += "X" + String(UnicodeScalar(UInt8(97 + d))) } else { s.append(ch) }
    }
    return s
}

func cocuklar(_ e: XMLElement) -> [XMLElement] { e.children?.compactMap { $0 as? XMLElement } ?? [] }

/// Kendisi hariç bütün alt öğeler, belge sırasıyla
func torunlar(_ e: XMLElement) -> [XMLElement] {
    var out: [XMLElement] = []
    for c in cocuklar(e) { out.append(c); out += torunlar(c) }
    return out
}

/// Bağlam altında adı eşleşen ilk öğe; önce doğrudan çocuklar, sonra derindekiler
func bul(_ baglam: XMLElement, _ ad: String) -> XMLElement? {
    let adlar: Set = [ad, kod(ad)]
    return cocuklar(baglam).first { adlar.contains($0.name ?? "") } ?? torunlar(baglam).first { adlar.contains($0.name ?? "") }
}

/// Aynı ad birden çok geçebilir (ör. <tarih>17/11/2025</tarih> ... <tarih></tarih>): ilk boş olmayan
func deger(_ baglam: XMLElement, _ ad: String) -> String {
    let adlar: Set = [ad, kod(ad)]
    for e in cocuklar(baglam).filter({ adlar.contains($0.name ?? "") }) + torunlar(baglam).filter({ adlar.contains($0.name ?? "") }) {
        guard cocuklar(e).isEmpty, let v = e.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        return v.trimmingCharacters(in: .newlines).replacingOccurrences(of: "\r", with: "")
    }
    return ""
}

struct UDFBelge {
    let metin: NSString
    var stiller: [String: [String: String]] = [:]

    func stil(_ e: XMLElement) -> [String: String] {
        var h: [String: String] = [:]
        if let r = e.attribute(forName: "resolver")?.stringValue, let s = stiller[r] { h = s }
        for a in e.attributes ?? [] { if let n = a.name, let v = a.stringValue { h[n] = v } }
        return h
    }

    /// Paragrafın gösterilecek parçaları: (metin, öğe); resim için metin "<img>"
    func parcalar(_ p: XMLElement, _ veri0: XMLElement?) -> [(String, XMLElement)] {
        var veri = veri0
        let ust = veri0
        if let v = veri, let g = p.attribute(forName: "GroupName")?.stringValue, let e = bul(v, g) { veri = e }
        var out: [(String, XMLElement)] = []
        var oncekiAlan = false
        for c in cocuklar(p) {
            if c.name == "image" { out.append(("<img>", c)); oncekiAlan = false; continue }
            var baglam = veri
            let grup = c.attribute(forName: "fieldGroupName")?.stringValue
            if let v = veri, let g = grup {
                guard let e = bul(v, g) else { continue }   // grup veride yok: bu parça gösterilmez
                baglam = e
            }
            let bas = Int(c.attribute(forName: "startOffset")?.stringValue ?? "") ?? 0
            let uzun = min(Int(c.attribute(forName: "length")?.stringValue ?? "") ?? 0, metin.length - bas)   // taşan parça kırpılır
            var t = ""
            if bas >= 0, uzun > 0 {
                t = metin.substring(with: NSRange(location: bas, length: uzun))
                    .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            }
            if c.name == "field", let b = baglam {
                let ad = c.attribute(forName: "fieldName")?.stringValue ?? ""
                if ad == "eol" { t = "\n" }
                else if ad == "ceol" { t = deger(b, ad) == "true" ? "\n" : "" }
                else {
                    t = deger(b, ad)   // değerdeki satır sonları korunur; değeri yoksa boş
                    if t.isEmpty, grup == nil, let u = ust, b !== u { t = deger(u, ad) }
                }
                if !t.isEmpty, oncekiAlan, let son = out.last?.0.last, !son.isWhitespace, t.first?.isWhitespace == false {
                    t = " " + t   // art arda gelen alan değerleri bitişmesin
                }
                oncekiAlan = oncekiAlan || !t.isEmpty
            } else { oncekiAlan = false }
            if !t.isEmpty { out.append((t, c)) }
        }
        return out
    }

    func paragraf(_ p: XMLElement, _ veri: XMLElement?) -> String {
        let ps = stil(p)
        let hiza = ["1": "center", "2": "right", "3": "justify"][ps["Alignment"] ?? ""] ?? "left"
        let tab = ps["TabSet"].flatMap { sayi(String($0.split(separator: ":").first ?? "")) } ?? 36
        var css = "text-align:\(hiza);tab-size:\(pt(tab))pt;"
        for (k, ozellik) in [("LeftIndent", "margin-left"), ("RightIndent", "margin-right"),
                             ("SpaceAbove", "margin-top"), ("SpaceBelow", "margin-bottom"),
                             ("FirstLineIndent", "text-indent")] {
            if let v = sayi(ps[k]) { css += "\(ozellik):\(pt(v))pt;" }
        }
        var html = ""
        for (t, c) in parcalar(p, veri) {
            if t == "<img>" {
                let b64 = (c.attribute(forName: "imageData")?.stringValue ?? "").filter { !$0.isWhitespace }
                guard !b64.isEmpty else { continue }
                let tur = b64.hasPrefix("/9j") ? "image/jpeg" : b64.hasPrefix("R0lG") ? "image/gif" : "image/png"
                html += "<img src=\"data:\(tur);base64,\(b64)\">"
                continue
            }
            let cs = stil(c)
            var rs = ""
            if cs["bold"] == "true" { rs += "font-weight:bold;" }
            if cs["italic"] == "true" { rs += "font-style:italic;" }
            if cs["underline"] == "true" { rs += "text-decoration:underline;" }
            if let s = sayi(cs["size"]) { rs += "font-size:\(pt(s))pt;" }
            if let f = cs["family"], f != "Dialog", f != "Editor" { rs += "font-family:'\(kacis(f))',serif;" }
            html += "<span style=\"\(rs)\">\(kacis(t))</span>"
        }
        return "<p style=\"\(css)\">\(html.isEmpty ? "&nbsp;" : html)</p>"
    }

    /// Tablonun gösterilecek satırları; dataRow verideki her satır için tekrarlanır
    func satirlar(_ tablo: XMLElement, _ veri: XMLElement?) -> [(XMLElement, XMLElement?)] {
        var out: [(XMLElement, XMLElement?)] = []
        for satir in tablo.elements(forName: "row") {
            if satir.attribute(forName: "rowType")?.stringValue == "dataRow", let v = veri {
                guard let vt = bul(v, tablo.attribute(forName: "tableName")?.stringValue ?? "") else { continue }
                let rn = satir.attribute(forName: "rowName")?.stringValue ?? ""
                let adlar: Set = [rn, kod(rn)]
                for vs in cocuklar(vt) where adlar.contains(vs.name ?? "") { out.append((satir, vs)) }
            } else { out.append((satir, veri)) }
        }
        return out
    }

    func genislikler(_ tablo: XMLElement, _ satir: XMLElement) -> [String?] {
        let n = satir.elements(forName: "cell").count
        for k in [satir.attribute(forName: "columnSpans")?.stringValue, tablo.attribute(forName: "columnSpans")?.stringValue] {
            let d = (k ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let top = d.reduce(0, +)
            if d.count == n, top > 0 { return d.map { String(format: "%.1f%%", $0 / top * 100) } }
        }
        return Array(repeating: nil, count: n)
    }

    func blok(_ dugum: XMLElement?, _ veri: XMLElement?) -> String {
        var cikti: [String] = []
        for c in dugum.map(cocuklar) ?? [] {
            if c.name == "paragraph" { cikti.append(paragraf(c, veri)) }
            else if c.name == "table" {
                let kenar = c.attribute(forName: "border")?.stringValue == "borderNone" ? "none" : "1px solid #000"
                cikti.append("<table>")
                for (satir, sv) in satirlar(c, veri) {
                    let hucreler = zip(satir.elements(forName: "cell"), genislikler(c, satir))
                        .map { "<td style=\"border:\(kenar)\($1.map { ";width:" + $0 } ?? "")\">\(blok($0, sv))</td>" }.joined()
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
    let pf = kok.elements(forName: "properties").first?.elements(forName: "pageFormat").first
    let kenar = ["topMargin", "rightMargin", "bottomMargin", "leftMargin"].map { k -> String in
        let v = sayi(pf?.attribute(forName: k)?.stringValue) ?? 42.5
        return pt(max(v, 28)) + "pt"
    }.joined(separator: " ")
    let govde = belge.blok(kok.elements(forName: "elements").first, kok.elements(forName: "data").first)
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
