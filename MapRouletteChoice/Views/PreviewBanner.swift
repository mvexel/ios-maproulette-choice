import SwiftUI

/// Above every screen of a previewed campaign (design/preview-mode.md §4.1): amber on navy, the
/// live page's signal colors, full width and not dismissible. After a refresh finds the campaign
/// published it offers to open it for real (§5).
struct PreviewBanner: View {
  let preview: CampaignPreview

  /// Brand navy and amber (brand/colors.json `textPrimary` and `accent`).
  private static var navy: Color { Color(red: 0x14 / 255, green: 0x21 / 255, blue: 0x3D / 255) }
  private static var amber: Color { Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255) }

  var body: some View {
    let published = preview.phase == .publishedNow
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Group {
        if published {
          Text(Wording.previewNowPublished).bold()
        } else {
          Text("\(Text(Wording.previewBannerTitle).bold()) \(Wording.previewBannerText)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(published ? Wording.openForReal : Wording.exitPreview) {
        published ? preview.openForReal() : preview.exit()
      }
      .font(.subheadline.weight(.semibold))
      .buttonStyle(.bordered)
      .tint(Self.amber)
      .frame(minHeight: 44)
    }
    .font(.subheadline)
    .foregroundStyle(Self.amber)
    .padding(.horizontal)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity)
    .background(Self.navy)
  }
}
