import SwiftUI

if CommandLine.arguments.contains(VirtualDisplayHostProtocol.argument) {
    VirtualDisplayHostMain.run()
} else {
    TeleprompterMirrorApp.main()
}
