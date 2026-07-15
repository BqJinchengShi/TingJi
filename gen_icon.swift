import AppKit

// 生成听记 App 图标：圆角蓝底 + 麦克风（听）+ "记"字（记）
let size = 512
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角渐变蓝背景
let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 112, yRadius: 112)
NSGradient(colors: [NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1),
                    NSColor(red: 0.10, green: 0.38, blue: 0.92, alpha: 1)])?.draw(in: path, angle: -90)

// 麦克风图标（听）- 白色
let micConfig = NSImage.SymbolConfiguration(pointSize: 190, weight: .semibold)
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(micConfig) {
    let micTinted = NSImage(size: mic.size)
    micTinted.lockFocus()
    mic.draw(in: NSRect(origin: .zero, size: mic.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: mic.size).fill(using: .sourceAtop)
    micTinted.unlockFocus()
    micTinted.draw(in: NSRect(x: 161, y: 230, width: 190, height: 190), from: NSRect(origin: .zero, size: micTinted.size), operation: .sourceOver, fraction: 1)
}

// "记"字（记）- 白色
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 180, weight: .bold),
    .foregroundColor: NSColor.white,
]
NSAttributedString(string: "记", attributes: attrs).draw(at: NSPoint(x: 178, y: 55))

image.unlockFocus()

// 导出 PNG
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "AppIcon.png"))
print("generated AppIcon.png")
