import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Links that open a campaign: `https://streettally.osm.lol/challenge/<id>` (a universal link;
/// without the app, the landing page), `mrchoice://challenge/<id>`, and the same path on any
/// https host.
enum CampaignLink {
  static let scheme = "mrchoice"
  /// The participant web host (`CAMPAIGN_LINK_HOST`), also the Associated Domains entry.
  static let host: String = {
    let value = (Bundle.main.infoDictionary?["MRCampaignLinkHost"] as? String)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    return value.isEmpty || value.contains("$(") ? "streettally.osm.lol" : value
  }()

  static func url(_ challenge: Int64) -> URL { URL(string: "\(scheme)://challenge/\(challenge)")! }

  /// The link to share and print: opens the app where installed, the landing page elsewhere.
  static func webURL(_ challenge: Int64, host: String = CampaignLink.host) -> URL {
    URL(string: "https://\(host)/challenge/\(challenge)")!
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
