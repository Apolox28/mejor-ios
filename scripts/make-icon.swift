// Genera el ícono 1024x1024 en el runner de macOS (no hace falta editor de imágenes).
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.11, blue: 0.35, alpha: 1),
    NSColor(calibratedRed: 0.89, green: 0.27, blue: 0.45, alpha: 1)
])!
gradient.draw(in: rect, angle: 60)

// Burbuja de chat
let bubble = NSBezierPath(roundedRect: NSRect(x: 212, y: 300, width: 600, height: 440), xRadius: 200, yRadius: 200)
bubble.move(to: NSPoint(x: 300, y: 340))
bubble.line(to: NSPoint(x: 230, y: 230))
bubble.line(to: NSPoint(x: 420, y: 310))
NSColor.white.setFill()
bubble.fill()

// Flecha de "enviado"
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 380, y: 520))
arrow.line(to: NSPoint(x: 660, y: 600))
arrow.line(to: NSPoint(x: 540, y: 420))
arrow.line(to: NSPoint(x: 500, y: 500))
arrow.close()
NSColor(calibratedRed: 0.89, green: 0.27, blue: 0.45, alpha: 1).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
