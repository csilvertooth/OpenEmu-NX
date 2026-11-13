// Copyright (c) 2020, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Cocoa

final class BackgroundImageView: NSView {

    var designBackground: NSColor? { didSet { needsDisplay = true } }

    @IBInspectable var background: NSImage?
    @IBInspectable var image: NSImage?

    // After IB wires up IBInspectable properties: use image drawing when images
    // are set (Controls panel wood texture), frosted glass otherwise (setup assistant).
    override func awakeFromNib() {
        super.awakeFromNib()
        if background == nil && image == nil {
            setupFrostedGlass()
        }
    }

    private func setupFrostedGlass() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        if let designBackground {
            designBackground.setFill(); bounds.fill()
            drawControllerBackdrop()
            return
        }
        background?.draw(in: dirtyRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
        image?.draw(in: dirtyRect, from: dirtyRect, operation: .sourceOver, fraction: 1, respectFlipped: isFlipped, hints: nil)
    }

    // Resolution-independent ambient lighting and circuit traces behind the controller.
    private func drawControllerBackdrop() {
        let stage = NSRect(x: 0, y: 0, width: bounds.width * 0.68, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: stage).addClip()
        let glow = NSGradient(starting: NSColor(calibratedRed: 0.34, green: 0.18, blue: 0.60, alpha: 0.65), ending: .clear)
        glow?.draw(fromCenter: NSPoint(x: stage.midX * 0.65, y: stage.midY), radius: 0,
                   toCenter: NSPoint(x: stage.midX, y: stage.midY), radius: stage.width * 0.65, options: [])
        let blue = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.65, alpha: 0.32), ending: .clear)
        blue?.draw(fromCenter: NSPoint(x: stage.maxX * 0.84, y: stage.height * 0.3), radius: 0,
                   toCenter: NSPoint(x: stage.maxX * 0.84, y: stage.height * 0.3), radius: stage.width * 0.48, options: [])
        for index in 0..<7 {
            let y = stage.height * (0.12 + CGFloat(index) * 0.12)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: stage.width * 0.18, y: y))
            path.line(to: NSPoint(x: stage.width * 0.29, y: y + 32))
            path.line(to: NSPoint(x: stage.width, y: y + 32))
            NXDesign.accent.withAlphaComponent(0.07).setStroke()
            path.lineWidth = 1; path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override var isFlipped: Bool { false }
}
