//
//  CommandRunner.swift
//  a-Shell — Agentic layer
//
//  A headless variant of SceneDelegate.executeCommand that runs a shell command
//  through ios_system and *captures* stdout/stderr into a String instead of
//  streaming it to the hterm terminal. This is what the agent's `run_bash` tool
//  calls.
//
//  It reuses SceneDelegate.commandQueue (the same serial queue the interactive
//  terminal uses) so agent commands and user-typed commands never run
//  concurrently against ios_system's per-session global streams.
//

import Foundation
import ios_system

extension SceneDelegate: AgentHost {

    /// Directory that relative agent paths resolve against.
    var agentWorkingDirectory: String {
        FileManager().currentDirectoryPath
    }

    /// AgentHost conformance: async wrapper around the completion-based core.
    func runBashCapturing(_ command: String, timeout: Int?) async -> String {
        await withCheckedContinuation { continuation in
            executeCommandCapturing(command, timeout: timeout) { output in
                continuation.resume(returning: output)
            }
        }
    }

    /// Run `command`, capturing combined stdout/stderr, and call `completion`
    /// on an arbitrary thread when the command finishes (or times out).
    func executeCommandCapturing(_ command: String,
                                 timeout: Int?,
                                 completion: @escaping (String) -> Void) {
        commandQueue.async {
            // --- set up private pipes for this capture run ---
            let stdinPipe = Pipe()
            let captureStdin = fdopen(stdinPipe.fileHandleForReading.fileDescriptor, "r")
            let ttyPipe = Pipe()
            let captureTty = fdopen(ttyPipe.fileHandleForReading.fileDescriptor, "r")
            let stdoutPipe = Pipe()
            let captureStdout = fdopen(stdoutPipe.fileHandleForWriting.fileDescriptor, "w")

            guard captureStdin != nil, captureStdout != nil, captureTty != nil else {
                completion("[agent] Could not create I/O streams for command.")
                return
            }

            let eot = self.endOfTransmission
            let bufferLock = NSLock()
            var buffer = Data()
            var eotSeen = false
            let drainSem = DispatchSemaphore(value: 0)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                bufferLock.lock()
                defer { bufferLock.unlock() }
                if let s = String(data: data, encoding: .utf8), s.contains(eot) {
                    let cleaned = s.replacingOccurrences(of: eot, with: "")
                    buffer.append(Data(cleaned.utf8))
                    if !eotSeen { eotSeen = true; drainSem.signal() }
                } else {
                    buffer.append(data)
                }
            }

            // --- point ios_system at our session + streams ---
            ios_switchSession(self.persistentIdentifier?.toCString())
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier?.toCString()))
            setenv("COLUMNS", "\(self.width)".toCString(), 1)
            setenv("LINES", "\(self.height)".toCString(), 1)
            ios_setWindowSize(Int32(self.width), Int32(self.height), self.persistentIdentifier?.toCString())
            thread_stdin = nil
            thread_stdout = nil
            thread_stderr = nil
            ios_setStreams(captureStdin, captureStdout, captureStdout)
            ios_settty(captureTty)
            setenv("LC_CTYPE", "UTF-8", 1)
            setlocale(LC_CTYPE, "UTF-8")

            // --- timeout watchdog: interrupt the running command ---
            let effectiveTimeout = (timeout ?? 60) > 0 ? (timeout ?? 60) : 60
            var timedOut = false
            let watchdog = DispatchWorkItem {
                timedOut = true
                // ios_kill() interrupts the currently-running command in the session
                // (this is the same call the terminal's Ctrl-C uses).
                ios_kill()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(effectiveTimeout),
                                              execute: watchdog)

            // --- run it ---
            let pid = ios_fork()
            ios_system(command)
            ios_waitpid(pid)
            ios_releaseThreadId(pid)
            watchdog.cancel()

            // --- signal end-of-output and drain the reader ---
            let writeOpen = fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_GETFD)
            if writeOpen >= 0 {
                stdoutPipe.fileHandleForWriting.write(Data(eot.utf8))
                _ = drainSem.wait(timeout: .now() + 5)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil

            // --- tear down pipes ---
            fclose(captureStdout)
            try? stdoutPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            fclose(captureStdin)
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            fclose(captureTty)
            try? ttyPipe.fileHandleForReading.close()
            try? ttyPipe.fileHandleForWriting.close()

            // Restore the session context so the interactive terminal is unaffected.
            ios_switchSession(self.persistentIdentifier?.toCString())
            ios_setContext(UnsafeMutableRawPointer(mutating: self.persistentIdentifier?.toCString()))

            bufferLock.lock()
            var out = String(decoding: buffer, as: UTF8.self)
            bufferLock.unlock()
            if timedOut {
                out += "\n[agent] Command timed out after \(effectiveTimeout)s and was interrupted."
            }
            if out.isEmpty { out = "[no output]" }
            completion(out)
        }
    }
}
