import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Links that open a campaign: `mrchoice://challenge/<id>`, and the same path on any https host
/// (ready for universal links once a domain serves an apple-app-site-association file).
/// `?preview=1` asks for preview mode (design/preview-mode.md §3), which only a draft honors.
enum CampaignLink {
  static let scheme = "mrchoice"

  static func url(_ challenge: Int64, preview: Bool = false) -> URL {
    URL(string: "\(scheme)://challenge/\(challenge)" + (preview ? "?preview=1" : ""))!
  }

  /// Whether a campaign link asks for preview mode (`preview=1`).
  static func isPreview(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .contains { $0.name == "preview" && $0.value == "1" } == true
  }

  /// The challenge id a link opens, or nil.
  static func challenge(from url: URL) -> Int64? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased()
    else { return nil }
    var parts = c.path.split(separator: "/").map(String.init)
    if scheme == Self.scheme {
      if let host = c.host, !host.isEmpty { parts.insert(host, at: 0) }
    } else if scheme != "https" {
      return nil
    }
    guard parts.count == 2, parts[0].lowercased() == "challenge", let id = Int64(parts[1]), id > 0 else { return nil }
    return id
  }

  /// A crisp QR code for `url`.
  static func qrCode(_ url: URL) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: cg)
  }
}
