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

final class ControlsPopUpButtonCell: NSPopUpButtonCell {
    
    override func drawBorderAndBackground(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSImage(named: "wood_popup_button")?.draw(in: cellFrame)
    }
    
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        image.draw(in: frame)
    }
    
    override func titleRect(forBounds cellFrame: NSRect) -> NSRect {
        // Keep AppKit's horizontal space for the selected icon and disclosure
        // arrows, but center the font we actually draw in the custom bezel.
        // Native popup baselines vary by macOS release and control size.
        var rect = super.titleRect(forBounds: cellFrame)
        let text = NSAttributedString(string: title, attributes: Self.attributes)
        rect.size.height = min(cellFrame.height, ceil(text.size().height))
        rect.origin.y = cellFrame.midY - rect.height / 2
        return rect
    }

    override func imageRect(forBounds cellFrame: NSRect) -> NSRect {
        var rect = super.imageRect(forBounds: cellFrame)
        if !rect.isEmpty {
            rect.origin.y = cellFrame.midY - rect.height / 2
        }
        return rect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // AppKit requires an alignment rule for both axes. Supplying only Y
        // edges raises an exception from NSViewAlignRect when Settings draws.
        let titleRect = controlView.backingAlignedRect(titleRect(forBounds: cellFrame),
                                                      options: [.alignMinXNearest, .alignMaxXNearest,
                                                                .alignMinYNearest, .alignMaxYNearest])
        let imageRect = imageRect(forBounds: cellFrame)

        if !titleRect.isEmpty {
            // Use the same measured attributed line for drawing rather than
            // relying on the native popup title layout inside our custom bezel.
            NSAttributedString(string: title, attributes: Self.attributes).draw(in: titleRect)
        }
        if !imageRect.isEmpty,
           let image = image {
            drawImage(image, withFrame: imageRect, in: controlView)
        }
    }

    private static let attributes: [NSAttributedString.Key : Any] = {
        
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        
        let attributes: [NSAttributedString.Key : Any] =
                                          [.font: NSFont.boldSystemFont(ofSize: 11),
                                .foregroundColor: NSColor.black,
                                         .shadow: NSShadow.oeControls,
                                 .paragraphStyle: style]
        
        return attributes
    }()
}
