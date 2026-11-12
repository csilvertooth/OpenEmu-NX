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

    @objc dynamic var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    @objc dynamic var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
    // Retained for the inherited storyboard binding while its old content is removed.
    @objc dynamic var specialThanks: NSAttributedString { NSAttributedString(string: "") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.subviews.forEach { $0.removeFromSuperview() }
        view.setFrameSize(NSSize(width: 680, height: 440))
        let banner = NSImageView(image: NSImage(named: "NXAboutBanner") ?? NSImage())
        banner.imageScaling = .scaleProportionallyUpOrDown
        banner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        banner.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        banner.setContentHuggingPriority(.defaultLow, for: .horizontal)
        banner.setContentHuggingPriority(.defaultLow, for: .vertical)
        banner.setAccessibilityLabel("OpenEmu-NX. Classic games. Together.")
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.alignment = .center
            return field
        }
        let version = label("OpenEmu-NX \(appVersion)", size: 19, weight: .semibold)
        let build = label("Build \(buildVersion)", size: 12)
        build.textColor = .secondaryLabelColor
        let credits = label("OpenEmu-NX by Chris Silvertooth\nBuilt on OpenEmu and OpenEmu-Silicon.\nWith thanks to their contributors and the emulator core teams.", size: 13)
        let licenses = label("Original credits and licenses are preserved in the project repository.", size: 11)
        licenses.textColor = .secondaryLabelColor
        let project = NSButton(title: "Project on GitHub", target: self, action: #selector(openProject))
        let releases = NSButton(title: "Releases and Updates", target: self, action: #selector(openReleases))
        let links = NSStackView(views: [project, releases])
        links.orientation = .horizontal
        links.spacing = 12
        let content = NSStackView(views: [version, build, credits, licenses, links])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            banner.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            banner.heightAnchor.constraint(equalTo: banner.widthAnchor, multiplier: 400.0 / 1280.0),
            content.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 20),
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            credits.widthAnchor.constraint(equalTo: content.widthAnchor),
            licenses.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.setContentSize(NSSize(width: 680, height: 440))
        view.window?.title = "About OpenEmu-NX"
    }
    @objc private func openProject() { open(AppDelegate.websiteAddress) }
    @objc private func openReleases() { open(AppDelegate.releaseNotesAddress) }
    private func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
    @IBAction func openWeblink(_ sender: AnyObject?) { openProject() }
}
