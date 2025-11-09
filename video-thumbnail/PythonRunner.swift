import Foundation

private func debugLog(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
    print("🪵 [\(file):\(line)] \(function) — \(message)")
}

struct ScriptResult {
    let output: String
    let exitCode: Int32
}

enum PythonRunnerError: Error {
    case scriptNotFound
    case failedToLaunch
    case outputDecoding
}

final class PythonRunner {
    private let pythonExecutable: String
    private let scriptURL: URL

    init(
        pythonExecutable: String = "/usr/bin/env",
        scriptURL: URL = URL(fileURLWithPath: "/Users/onsite/.personal_projects/video-thumbnail/video-thumbnail/video_thumbnail.py")
    ) {
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
        debugLog("PythonRunner init. pythonExecutable='\(pythonExecutable)', scriptURL='\(scriptURL.path)'")
    }

    func runScript(with fileURL: URL, s3Path: String) async throws -> ScriptResult {
        debugLog("runScript called. fileURL='\(fileURL.path)', s3Path='\(s3Path)'")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            debugLog("Script not found at \(scriptURL.path)")
            throw PythonRunnerError.scriptNotFound
        }
        
        guard !s3Path.isEmpty else {
            debugLog("s3Path empty, cannot launch")
            throw PythonRunnerError.failedToLaunch
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: self.pythonExecutable)
                task.arguments = ["python3", self.scriptURL.path, fileURL.path, s3Path]
                debugLog("Launching process: \(self.pythonExecutable) \(task.arguments?.joined(separator: " ") ?? "")")
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                task.standardOutput = outputPipe
                task.standardError = errorPipe

                do {
                    try task.run()
                } catch {
                    debugLog("Failed to launch process: \(error.localizedDescription)")
                    continuation.resume(throwing: PythonRunnerError.failedToLaunch)
                    return
                }

                task.waitUntilExit()
                let exit = task.terminationStatus
                debugLog("Process finished. exitCode=\(exit)")

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                guard let outputString = String(data: outputData + errorData, encoding: .utf8) else {
                    debugLog("Failed to decode process output")
                    continuation.resume(throwing: PythonRunnerError.outputDecoding)
                    return
                }

                debugLog("Process output length=\(outputString.count)")
                let result = ScriptResult(output: outputString, exitCode: exit)
                continuation.resume(returning: result)
            }
        }
    }
}
