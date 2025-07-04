import Foundation
import NIOCore
import NIOSSH

/// Handles an interactive shell channel and fulfils promises when sentinels are encountered.
final class StreamingShellHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SSHChannelData
    
    struct Pending {
        let sentinel: String
        let promise: EventLoopPromise<String>
        var buffer: String = ""
    }
    
    private var queue: [Pending] = []
    private var hasReceivedAnyData = false
    private var totalDataReceived = 0
    
    /// Called by ChannelExecutor when a new command is queued.
    func addCommand(sentinel: String, promise: EventLoopPromise<String>) {
        queue.append(Pending(sentinel: sentinel, promise: promise))
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        // Handler is ready
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("🔍 StreamingShellHandler: ✓ Channel active")
        context.fireChannelActive()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if !queue.isEmpty {
            print("🔍 StreamingShellHandler: ❌ Channel closed with pending commands")
        }
        context.fireChannelInactive()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !hasReceivedAnyData {
            hasReceivedAnyData = true
            print("🔍 StreamingShellHandler: ✓ Channel receiving data")
        }
        
        let payload = unwrapInboundIn(data)
        
        guard case .byteBuffer(let buf) = payload.data,
              let string = buf.getString(at: 0, length: buf.readableBytes) else { 
            return 
        }
        
        totalDataReceived += string.count
        
        // Handle stderr separately
        if payload.type == .stdErr {
            print("🔍 StreamingShellHandler: ❌ Stderr: '\(string.trimmingCharacters(in: .whitespacesAndNewlines))'")
            return
        }
        
        guard !queue.isEmpty else { 
            return 
        }
        
        // Accumulate all incoming data
        queue[0].buffer += string
        
        // Process the buffer to look for the sentinel
        let currentBuffer = queue[0].buffer
        let expectedSentinel = queue[0].sentinel
        
        // Try both formats:
        // 1. Interactive osascript format: => "sentinel"
        // 2. Shell format: plain sentinel
        let osascriptSentinelPattern = "=> \"\(expectedSentinel)\""
        let shellSentinelPattern = expectedSentinel
        
        var sentinelRange: Range<String.Index>?
        var isOsascriptFormat = false
        
        // Check for osascript format first
        if let range = currentBuffer.range(of: osascriptSentinelPattern) {
            sentinelRange = range
            isOsascriptFormat = true
        } else if let range = currentBuffer.range(of: shellSentinelPattern) {
            sentinelRange = range
            isOsascriptFormat = false
        }
        
        if let sentinelRange = sentinelRange {
            // Found the sentinel - extract the output before it
            let outputPart = String(currentBuffer[..<sentinelRange.lowerBound])
            
            let scriptOutput: String
            
            if isOsascriptFormat {
                // Parse AppleScript output - look for => "result" lines
                scriptOutput = extractAppleScriptResult(from: outputPart)
            } else {
                // Parse shell/mixed output - look for AppleScript results or clean shell output
                scriptOutput = extractCleanOutput(from: outputPart)
            }
            
            print("🔍 StreamingShellHandler: ✓ Result: '\(scriptOutput)'")
            
            // Complete the promise with the parsed output
            let pending = queue.removeFirst()
            pending.promise.succeed(scriptOutput)
        }
    }
    
    /// Extract clean AppleScript result from => "result" format
    private func extractAppleScriptResult(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        
        // Look for the last meaningful result line before the sentinel
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("=> ") {
                let content = String(trimmed.dropFirst(3))
                // Remove surrounding quotes if present
                if content.hasPrefix("\"") && content.hasSuffix("\"") && content.count > 1 {
                    return String(content.dropFirst().dropLast())
                } else {
                    return content
                }
            }
        }
        
        // If no => format found, look for any meaningful result
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && 
               !trimmed.hasPrefix("?>") && 
               !trimmed.hasPrefix(">>") && 
               !trimmed.hasPrefix(">") && 
               !trimmed.contains("ryan@") &&
               !trimmed.hasPrefix("[") &&
               !trimmed.hasPrefix("]") &&
               !trimmed.contains("Welcome to fish") &&
               !trimmed.contains("osascript") &&
               !trimmed.hasPrefix("tell ") &&
               !trimmed.hasPrefix("end tell") &&
               !trimmed.contains("do shell script") &&
               !trimmed.contains("echo ") &&
               trimmed.count < 200 { // Avoid very long output
                // Strip leading quote if present (common in AppleScript results)
                if trimmed.hasPrefix("\"") {
                    return String(trimmed.dropFirst())
                }
                return trimmed
            }
        }
        return ""
    }
    
    /// Extract clean output from mixed shell/AppleScript output
    private func extractCleanOutput(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        
        // First, look for AppleScript result lines (checking in reverse order for last result)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("=> \"") && trimmed.hasSuffix("\"") {
                // Extract content between quotes
                return String(trimmed.dropFirst(3).dropLast())
            } else if trimmed.hasPrefix("=> ") {
                // Extract content after =>
                return String(trimmed.dropFirst(3))
            }
        }
        
        // If no AppleScript result, find any meaningful output
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip all the noise
            if trimmed.isEmpty ||
               trimmed.hasPrefix("?>") ||
               trimmed.hasPrefix(">>") ||
               trimmed.hasPrefix(">") ||
               trimmed.contains("ryan@") ||
               trimmed.hasPrefix("]") ||
               trimmed.hasPrefix("[") ||
               trimmed.contains("Welcome to fish") ||
               trimmed.contains("Type help") ||
               trimmed.contains("Last login") ||
               trimmed.hasPrefix("/bin/sh") ||
               trimmed.hasPrefix("bash -c") ||
               trimmed.hasPrefix("tell ") ||
               trimmed.hasPrefix("end tell") ||
               trimmed.contains("do shell script") ||
               trimmed.contains("osascript") ||
               trimmed.contains("echo ") ||
               trimmed.contains("APPLESCRIPT") {
                continue
            }
            
            // Take the first (latest) clean line we find
            if trimmed.count < 200 { // Avoid very long output
                // Strip leading quote if present (common in AppleScript results)
                if trimmed.hasPrefix("\"") {
                    return String(trimmed.dropFirst())
                }
                return trimmed
            }
        }
        
        return ""
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("🔍 StreamingShellHandler: ❌ Error caught: \(error)")
        if let pending = queue.first {
            print("🔍 StreamingShellHandler: Failing pending promise due to error")
            pending.promise.fail(error)
            queue.removeAll()
        }
        context.close(promise: nil)
    }
} 
