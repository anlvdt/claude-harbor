import Foundation
@main struct BackendTests {
    static func main() async throws {
        let data = try await executePython(["-c", "import sys; sys.stdout.write('x'*1000000); sys.stderr.write('e'*200000)"])
        precondition(data.count == 1000000)
        do {
            _ = try await executePython(["-c", "import time; time.sleep(20)"], timeout: 0.2)
            fatalError("timeout was not enforced")
        } catch { precondition(error.localizedDescription.contains("timed out")) }
        do {
            _ = try await executePython(["-c", "import sys; sys.stdout.write('x'*10000000)"])
            fatalError("output bound was not enforced")
        } catch { precondition(error.localizedDescription.contains("limit")) }
        print("PASS: concurrent pipe drain, timeout, output limit")
    }
}
