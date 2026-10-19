import Foundation
import QuickLookUI
import UniformTypeIdentifiers

// Hızlı Bakış eklentisi: Finder'da .udf seçilip boşluk tuşuna basılınca belgeyi biçimli gösterir.
// Yalnızca okur; dosyaya dokunmaz, hiçbir yere bağlanmaz.

@objc(OnizlemeSaglayici)
class OnizlemeSaglayici: QLPreviewProvider, QLPreviewingController {
    func providePreview(for istek: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let ad = istek.fileURL.lastPathComponent
        let html: String
        do { html = try udfHTML(try Data(contentsOf: istek.fileURL), baslik: ad) }
        catch { html = hataHTML(error, baslik: ad) }
        let yanit = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 860, height: 1100)) { _ in
            Data(html.utf8)
        }
        yanit.title = ad
        return yanit
    }
}
