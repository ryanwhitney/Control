import Foundation
import NIOCore
import NIOSSH

/// Handles an interactive shell channel and fulfils promises when sentinels are encountered.
final class StreamingShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    
    struct Pending {
        let sentinel: String
        let promise: EventLoopPromise<String>
        var buffer: String = ""
    }
    
    private var queue: [Pending] = []
    private var hasReceivedAnyData = false
    private var totalDataReceived = 0
    private var greetingStripped = false
    
    /// Called by ChannelExecutor when a new command is queued.
    func addCommand(sentinel: String, promise: EventLoopPromise<String>) {
        queue.append(Pending(sentinel: sentinel, promise: promise))
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        // Handler is ready
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Channel setup logged by SSHClient
        context.fireChannelActive()
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if !queue.isEmpty {
            print("🔍 StreamingShellHandler: ❌ Channel closed with \(queue.count) pending commands – failing them")
            for pending in queue {
                pending.promise.fail(SSHError.channelError("Channel closed unexpectedly"))
            }
            queue.removeAll()
        }
        context.fireChannelInactive()
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !hasReceivedAnyData {
            hasReceivedAnyData = true
            // Data flow is implied by successful commands; no need to log
        }
        
        let payload = unwrapInboundIn(data)
        
        guard case .byteBuffer(let buf) = payload.data,
              let string = buf.getString(at: 0, length: buf.readableBytes) else { 
            return 
        }
        
        totalDataReceived += string.count
        
        // Handle stderr separately
        if payload.type == .stdErr {
            print("🔍 StreamingShellHandler: ❌ Stderr: '\(string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))'")
            // If we have a pending command and receive stderr, it's likely an error
            if !queue.isEmpty {
                let pending = queue.removeFirst()
                pending.promise.fail(SSHError.channelError("AppleScript stderr: \(string.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
            return
        }
        
        guard !queue.isEmpty else { 
            return 
        }
        
        var incoming = string
        
        // One-time removal of typical shell / osascript greetings to avoid corrupting the first command's buffer.
        if !greetingStripped {
            greetingStripped = true
            let greetingPatterns = [
                "Welcome to fish",
                "Type 'help' for instructions",
                "Last login",
                "osascript -e"
            ]
            // Remove any lines containing the greeting patterns
            let filteredLines = incoming
                .components(separatedBy: .newlines)
                .filter { line in !greetingPatterns.contains(where: { pattern in line.contains(pattern) }) }
            incoming = filteredLines.joined(separator: "\n")
        }
        
        queue[0].buffer += incoming
        
        // Process the buffer to look for the sentinel
        let currentBuffer = queue[0].buffer
        let expectedSentinel = queue[0].sentinel
        
        // Check if buffer is getting too large (possible stuck command)
        if currentBuffer.count > 100000 {
            print("🔍 StreamingShellHandler: ⚠️ Buffer overflow - command may be stuck")
            let pending = queue.removeFirst()
            pending.promise.fail(SSHError.channelError("Buffer overflow - response too large"))
            context.close(promise: nil)
            return
        }
        
        // Try both formats:
        // 1. Interactive osascript format: => "sentinel"
        // 2. Direct AppleScript result format with our sentinel
        let osascriptSentinelPattern = "=> \"\(expectedSentinel)\""
        let directSentinelPattern = "=> \"\(expectedSentinel)\""  // Same as osascript pattern
        
        var sentinelRange: Range<String.Index>?
        var isOsascriptFormat = false
        
        // Check for osascript format first
        if let range = currentBuffer.range(of: osascriptSentinelPattern) {
            sentinelRange = range
            isOsascriptFormat = true
        } else if let range = currentBuffer.range(of: directSentinelPattern, options: .backwards) {
            // This is also an AppleScript result format
            sentinelRange = range
            isOsascriptFormat = true
        }
        
        if let sentinelRange = sentinelRange {
            // Found the sentinel - extract the output before it
            let outputPart = String(currentBuffer[..<sentinelRange.lowerBound])
            
            let scriptOutput: String
            
            if isOsascriptFormat {
                // Parse AppleScript output - look for => "result" lines
                let (result, isError) = extractAppleScriptResult(from: outputPart)
                if isError {
                    // Complete with error
                    let pending = queue.removeFirst()
                    pending.promise.fail(SSHError.channelError("AppleScript error: \(result)"))
                    context.close(promise: nil)
                    return
                }
                scriptOutput = result
            } else {
                // Parse shell/mixed output - look for AppleScript results or clean shell output
                scriptOutput = extractCleanOutput(from: outputPart)
            }
            
            // Complete the promise with the parsed output
            let pending = queue.removeFirst()
            pending.promise.succeed(scriptOutput)
        }
    }
    
    /// Extract clean AppleScript result from => "result" format
    /// Returns (result, isError) tuple
    private func extractAppleScriptResult(from output: String) -> (String, Bool) {
        let lines = output.components(separatedBy: .newlines)
        
        // Look for the last meaningful result line before the sentinel
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for AppleScript error indicators
            if trimmed.hasPrefix("!!") || 
               trimmed.contains("error \"") ||
               trimmed.contains("can't go here") ||
               trimmed.contains("is not defined") ||
               trimmed.contains("doesn't understand") ||
               trimmed.contains("Can't get") ||
               trimmed.contains("Can't make") {
                // This is an error message
                return (trimmed, true)
            }
            
            if trimmed.hasPrefix("=> ") {
                let content = String(trimmed.dropFirst(3))
                // Check if the result itself is an error
                if content.hasPrefix("!!") || 
                   content.contains("error \"") ||
                   content.contains("can't go here") ||
                   content.contains("is not defined") {
                    return (content, true)
                }
                
                // Remove surrounding quotes if present
                var unquoted = content
                if unquoted.hasPrefix("\"") && unquoted.hasSuffix("\"") && unquoted.count > 1 {
                    unquoted = String(unquoted.dropFirst().dropLast())
                }
                
                // Prefer lines containing our status separator or booleans / numbers
                if unquoted.contains("|||") || unquoted == "true" || unquoted == "false" || Int(unquoted) != nil {
                    return (unquoted, false)
                }
                
                // Skip noisy "set ..." echoes from the interpreter
                if unquoted.hasPrefix("set ") {
                    continue
                }
                
                return (unquoted, false)
            }
        }
        
        // If no => format found, look for any meaningful result
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip noise and check for errors
            if !trimmed.isEmpty && 
               !trimmed.hasPrefix("?>") && 
               !trimmed.hasPrefix(">>") && 
               !trimmed.hasPrefix(">") && 
               !trimmed.contains("ryan@") &&
               !trimmed.hasPrefix("[") &&
               !trimmed.hasPrefix("]") &&
               !trimmed.contains("Welcome to fish") &&
               !trimmed.hasPrefix("tell ") &&
               !trimmed.hasPrefix("end tell") &&
               trimmed.count < 200 { // Avoid very long output
                
                // Check for error indicators
                if trimmed.hasPrefix("!!") || 
                   trimmed.contains("error") ||
                   trimmed.contains("can't") ||
                   trimmed.contains("is not defined") {
                    return (trimmed, true)
                }
                
                // Strip leading quote if present (common in AppleScript results)
                if trimmed.hasPrefix("\"") {
                    return (String(trimmed.dropFirst()), false)
                }
                return (trimmed, false)
            }
        }
        return ("", false)
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
            
            // Skip all the noise - but be more precise about what we filter
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
