// Copyright (c) 2019, OpenEmu Team
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

final class AboutViewController: NSViewController {
    
    @IBOutlet weak var websiteLink: TextButton!
    @IBOutlet weak var gitHubLink: TextButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Replace the inherited logo artwork while retaining upstream credits below.
        view.subviews.compactMap { $0 as? NSImageView }.forEach { $0.isHidden = true }
        let backdrop = NXAboutBackdrop(frame: view.bounds)
        backdrop.autoresizingMask = [.width, .height]
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)
        websiteLink.title = "Project on GitHub"
        gitHubLink.title = "Releases and Updates"
        
        let color = NSColor(from: "#526ba0")
        let hoverColor = NSColor(from: "#9c2a32")
        
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowOffset = NSMakeSize(0, -1)
        
        websiteLink.font = .boldSystemFont(ofSize: 12)
        websiteLink.textShadow = shadow
        websiteLink.textColor = color
        websiteLink.textColorHover = hoverColor
        
        shadow.shadowColor = .black.withAlphaComponent(0.4)
        
        gitHubLink.font = .boldSystemFont(ofSize: 11)
        gitHubLink.textShadow = shadow
        gitHubLink.textColor = color
        gitHubLink.textColorHover = hoverColor
    }
    
    @objc dynamic var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    
    @objc dynamic var buildVersion: String {
        return Bundle.main.infoDictionary!["OEBuildVersion"] as? String ?? ""
    }
    
    @objc dynamic lazy var specialThanks: NSAttributedString = {
        let msg = NSLocalizedString("Built on OpenEmu and OpenEmu-Silicon.\nThank you to their contributors and\nthe emulator core teams. Original\ncredits and licenses are preserved\nin our project repository.", comment: "Special thanks message (about window).")
        let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraphStyle.alignment = .center
        paragraphStyle.lineHeightMultiple = 1.225
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: NSColor.white
        ]
        return NSAttributedString(string: msg, attributes: attributes)
    }()
    
    @IBAction func openWeblink(_ sender: AnyObject?) {
        if let button = sender as? NSButton {
            let address = button === gitHubLink ? AppDelegate.releaseNotesAddress : AppDelegate.websiteAddress
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        }
    }
}


private final class NXAboutBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.16, alpha: 1),
                   ending: NSColor(calibratedRed: 0.17, green: 0.10, blue: 0.28, alpha: 1))?
            .draw(in: bounds, angle: 90)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title = NSAttributedString(string: "OpenEmu-NX", attributes: [
            .font: NSFont.systemFont(ofSize: 43, weight: .bold),
            .foregroundColor: NSColor.white, .paragraphStyle: style
        ])
        title.draw(in: NSRect(x: 12, y: 300, width: bounds.width - 24, height: 58))
        let subtitle = NSAttributedString(string: "Classic games. Together.", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.64, green: 0.74, blue: 1, alpha: 1),
            .paragraphStyle: style
        ])
        subtitle.draw(in: NSRect(x: 12, y: 273, width: bounds.width - 24, height: 24))
    }
}
