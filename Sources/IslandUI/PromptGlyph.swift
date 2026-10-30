import AppKit
import SwiftUI

public enum PromptGlyph {
    /// 메뉴바용 템플릿 이미지. 채운 사각형에서 `>_`를 뚫어 뒤 배경이 글자로 비친다.
    /// 색은 시스템이 메뉴바 밝기에 맞춰 입힌다.
    public static func statusImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let box = rect.insetBy(dx: size * 0.04, dy: size * 0.12)
            context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()

            context.setBlendMode(.destinationOut)
            let text = NSAttributedString(string: ">_", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: size * 0.62, weight: .bold),
                .foregroundColor: NSColor.black,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2 + size * 0.03))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 앱 아이콘. 노란 배경에 검은 `>_`.
public struct AppIconView: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.185, style: .continuous)
                .fill(Color(red: 1.00, green: 0.84, blue: 0.04))
            Text(">_")
                .font(.system(size: size * 0.4, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
        }
        .frame(width: size * 0.824, height: size * 0.824)
        .frame(width: size, height: size)
    }
}
