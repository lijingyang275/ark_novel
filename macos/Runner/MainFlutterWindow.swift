import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isMovableByWindowBackground = true
    self.styleMask.insert(.fullSizeContentView)
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = NSSize(width: 480, height: 600)
    self.setFrameAutosaveName("Main") // 记住窗口大小和位置

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
