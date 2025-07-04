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
    
    /// Called by ChannelExecutor when a new command is queued.
    func addCommand(sentinel: String, promise: EventLoopPromise<String>) {
        queue.append(Pending(sentinel: sentinel, promise: promise))
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = payload.data,
              var string = buf.getString(at: 0, length: buf.readableBytes) else { return }
        
        while !queue.isEmpty {
            var front = queue[0]
            front.buffer += string
            if let range = front.buffer.range(of: front.sentinel) {
                let output = String(front.buffer[..<range.lowerBound])
                front.promise.succeed(output.trimmingCharacters(in: .whitespacesAndNewlines))
                queue.removeFirst()
                // Remove consumed part including sentinel from string and continue searching for next sentinel
                string = String(front.buffer[range.upperBound...]) + string.dropFirst(string.count)
            } else {
                // Not complete yet
                queue[0] = front
                break
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let pending = queue.first {
            pending.promise.fail(error)
            queue.removeAll()
        }
        context.close(promise: nil)
    }
} 