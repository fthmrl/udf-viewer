import AppKit

// UDF Viewer: UYAP .udf evrakını Finder'da boşluk tuşuyla (Hızlı Bakış) biçimli gösterir.
// Asıl iş PlugIns/UDFOnizleme.appex eklentisindedir; bu uygulama eklentiyi sisteme tanıtır ve günceller.
// Çift tıklama UYAP Doküman Editörü'nde kalır.

let SURUM = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
let KLASOR_ADI = "UDF VIEWER"
let GITHUB_DEPO = "fthmrl/udf-viewer"
let UYGULAMA_ADI = "UDF Viewer"

/// Her sürümün yenilikleri; güncellemeden sonraki ilk açılışta bir kez gösterilir.
let YENILIKLER: [Int: [String]] = [
    1: ["Finder'da bir .udf seçip boşluk tuşuna basın: evrak biçimiyle Hızlı Bakış'ta görünür."],
    2: ["UYAP form şablonlu evraklarda (haciz, tebligat, kesinleştirme talebi vb.) alan adları yerine asıl bilgiler görünür."],
    3: ["Takip talebi, ödeme emri gibi gruplu UYAP şablonları doğru görünür: boş bölümler gizlenir, alacak tablosu satır satır dolar.",
        "Tablo sütunları evraktaki genişliklerle gösterilir."],
]

let uygulamaYolu = Bundle.main.bundleURL

struct SurumBilgisi: Decodable { let surum: Int; let dosya: String; let notlar: [String]? }

/// OneDrive'daki AI/UDF VIEWER klasörü (hesap adı her Mac'te farklı olabilir).
func yayimKlasoru() -> URL? {
    let fm = FileManager.default
    let cs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
    let hesaplar = (try? fm.contentsOfDirectory(at: cs, includingPropertiesForKeys: nil)) ?? []
    for h in hesaplar where h.lastPathComponent.hasPrefix("OneDrive") {
        for ai in ["AI", "Aİ"] {
            let k = h.appendingPathComponent(ai).appendingPathComponent(KLASOR_ADI)
            if fm.fileExists(atPath: k.appendingPathComponent("surum.json").path) { return k }
        }
    }
    return nil
}

func uyari(_ baslik: String, _ metin: String, _ dugmeler: [String] = ["Tamam"]) -> Int {
    let a = NSAlert()
    a.messageText = baslik
    a.informativeText = metin
    a.icon = NSApp.applicationIconImage
    for d in dugmeler { a.addButton(withTitle: d) }
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

func calistir(_ yol: String, _ arg: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: yol)
    p.arguments = arg
    do { try p.run(); p.waitUntilExit() } catch { return false }
    return p.terminationStatus == 0
}

/// İnternetten tek bir küçük dosya okur (yalnızca GET; hiçbir veri gönderilmez).
func indir(_ url: URL, zamanAsimi: TimeInterval) -> Data? {
    var sonuc: Data?
    let s = DispatchSemaphore(value: 0)
    var istek = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: zamanAsimi)
    istek.httpMethod = "GET"
    URLSession.shared.dataTask(with: istek) { d, r, _ in
        if (r as? HTTPURLResponse)?.statusCode == 200 { sonuc = d }
        s.signal()
    }.resume()
    s.wait()
    return sonuc
}

/// En yeni sürüm: önce GitHub'daki son yayın, sonra (varsa) OneDrive klasörü; hangisi büyükse.
func enYeniSurum() -> (SurumBilgisi, URL)? {
    var adaylar: [(SurumBilgisi, URL)] = []
    let gh = URL(string: "https://github.com/\(GITHUB_DEPO)/releases/latest/download/")!
    if let d = indir(gh.appendingPathComponent("surum.json"), zamanAsimi: 4),
       let b = try? JSONDecoder().decode(SurumBilgisi.self, from: d) {
        adaylar.append((b, URL(string: "https://github.com/\(GITHUB_DEPO)/releases/download/v\(b.surum)/\(b.dosya)")!))
    }
    if let k = yayimKlasoru(),
       let d = try? Data(contentsOf: k.appendingPathComponent("surum.json")),
       let b = try? JSONDecoder().decode(SurumBilgisi.self, from: d),
       FileManager.default.fileExists(atPath: k.appendingPathComponent(b.dosya).path) {
        adaylar.append((b, k.appendingPathComponent(b.dosya)))
    }
    return adaylar.filter { $0.0.surum > SURUM }.max { $0.0.surum < $1.0.surum }
}

/// Yeni sürüm varsa sorar; kabul edilirse kurar, yeni sürümü açar ve true döner.
func guncellemeVarsaSor() -> Bool {
    guard let (b, kaynak) = enYeniSurum() else { return false }
    var metin = "\(UYGULAMA_ADI) v\(b.surum) yayımlandı (yüklü olan: v\(SURUM))."
    if let n = b.notlar, !n.isEmpty { metin += "\n\n" + n.map { "• " + $0 }.joined(separator: "\n") }
    metin += "\n\nYeni sürüm yüklensin mi?"
    if uyari("Yeni sürüm var", metin, ["Yükle", "Sonra"]) != 0 { return false }

    let fm = FileManager.default
    let gecici = fm.temporaryDirectory.appendingPathComponent("udfviewer-guncelleme-\(UUID().uuidString)")
    try? fm.createDirectory(at: gecici, withIntermediateDirectories: true)
    var zip = kaynak
    if !kaynak.isFileURL {
        zip = gecici.appendingPathComponent(b.dosya)
        guard let d = indir(kaynak, zamanAsimi: 120), (try? d.write(to: zip)) != nil else {
            _ = uyari("Güncelleme indirilemedi", "İnternet bağlantınızı kontrol edin.")
            return false
        }
    }
    let acilan = gecici.appendingPathComponent("acilan")
    guard calistir("/usr/bin/ditto", ["-x", "-k", zip.path, acilan.path]),
          let yeni = (try? fm.contentsOfDirectory(at: acilan, includingPropertiesForKeys: nil))?
              .first(where: { $0.pathExtension == "app" }),
          (try? fm.replaceItemAt(uygulamaYolu, withItemAt: yeni)) != nil else {
        _ = uyari("Güncelleme yüklenemedi", "Daha sonra yeniden deneyin.")
        return false
    }
    _ = calistir("/usr/bin/xattr", ["-dr", "com.apple.quarantine", uygulamaYolu.path])
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: uygulamaYolu, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    return true
}

/// Hızlı Bakış eklentisini sisteme tanıtır ve önbelleği yeniler (her açılışta; zararsız).
func eklentiyiKaydet() {
    let eklenti = uygulamaYolu.appendingPathComponent("Contents/PlugIns/UDFOnizleme.appex").path
    _ = calistir("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", uygulamaYolu.path])
    _ = calistir("/usr/bin/pluginkit", ["-a", eklenti])
    _ = calistir("/usr/bin/pluginkit", ["-e", "use", "-i", "com.meralavukatlik.udfviewer.onizleme"])
    _ = calistir("/usr/bin/qlmanage", ["-r"])
}

class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if guncellemeVarsaSor() { return }
            eklentiyiKaydet()
            let ud = UserDefaults.standard
            var metin = "Finder'da bir .udf evrakı seçip boşluk tuşuna basın; evrak biçimiyle Hızlı Bakış'ta görünür.\n\nÇift tıklayınca evrak her zamanki gibi UYAP Doküman Editörü'nde açılır."
            if ud.integer(forKey: "gorulenSurum") < SURUM, let y = YENILIKLER[SURUM] {
                metin = "Yenilikler — v\(SURUM)\n" + y.map { "• " + $0 }.joined(separator: "\n") + "\n\n" + metin
            }
            ud.set(SURUM, forKey: "gorulenSurum")
            _ = uyari("\(UYGULAMA_ADI) hazır (v\(SURUM))", metin)
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
