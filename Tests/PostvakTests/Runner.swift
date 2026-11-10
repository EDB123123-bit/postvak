import Testing
import Foundation

@main
struct Runner {
    static func main() async {
        setenv("POSTVAK_NO_BACKOFF", "1", 1)
        let code: CInt = await Testing.__swiftPMEntryPoint()
        exit(code)
    }
}
