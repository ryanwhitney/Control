import Foundation
import NIOCore
import NIOSSH

/// Bridges the interactive `osascript -i` channel to EventLoop promises. The
/// framing/parsing lives in `StreamingResponseParser` (pure, unit-tested); this
/// handler owns only the NIO plumbing — feeding inbound bytes to the parser and
/// resolving the matching promise when a command completes.
///
/// All state is confined to the channel's EventLoop: `channelRead`/`errorCaught`
/// run there, and `addCommand`/`failCommand` are invoked by `ChannelExecutor`
/// via `eventLoop.execute` / `scheduleTask`. Because every access is on that one
/// loop, it is safe to hand the reference into those (`@Sendable`) closures —
/// hence `@unchecked Sendable`.
final class StreamingShellHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var parser = StreamingResponseParser()
    private var promises: [String: EventLoopPromise<String>] = [:]

    /// Register a command awaiting its sentinel. MUST be called on the event loop.
    func addCommand(sentinel: String, promise: EventLoopPromise<String>) {
        parser.addCommand(sentinel: sentinel)
        promises[sentinel] = promise
    }

    /// Remove and fail the pending command with this sentinel (no-op if it has
    /// already completed or is gone). MUST be called on the event loop. Used on
    /// timeout so a stale head can never misroute subsequent commands.
    func failCommand(sentinel: String, error: Error) {
        parser.removeCommand(sentinel: sentinel)
        promises.removeValue(forKey: sentinel)?.fail(error)
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !promises.isEmpty {
            sshLog("🔍 StreamingShellHandler: channel closed with \(promises.count) pending – failing them")
        }
        failAllPromises(SSHError.channelError("Channel closed unexpectedly"))
        parser.reset()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        // Over a PTY, stdout and stderr are merged into the channel stream; treat
        // both the same so `!! ` error lines are parsed wherever they arrive.
        guard case .byteBuffer(let buf) = payload.data,
              let chunk = buf.getString(at: 0, length: buf.readableBytes) else {
            return
        }

        for completion in parser.ingest(chunk) {
            // AppleScript-level errors come back as output (channel stays warm);
            // only transport failures (below / channelInactive) fail the promise.
            promises.removeValue(forKey: completion.sentinel)?.succeed(completion.output)
        }

        // Safety valve: if a sentinel never arrives and the buffer grows without
        // bound, fail the head and reset rather than leak memory.
        if parser.bufferedByteCount > parser.maxLineBuffer {
            sshLog("🔍 StreamingShellHandler: ⚠️ line buffer overflow – resetting channel")
            if let head = parser.headSentinel {
                parser.removeCommand(sentinel: head)
                promises.removeValue(forKey: head)?.fail(SSHError.channelError("Response too large"))
            }
            parser.reset()
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // tcpShutdown is expected during orderly disconnects.
        if String(describing: error).contains("tcpShutdown") {
            sshLog("🔍 StreamingShellHandler: channel closed (tcpShutdown)")
        } else {
            sshLog("🔍 StreamingShellHandler: ❌ error caught: \(error)")
        }
        failAllPromises(error)
        parser.reset()
        context.close(promise: nil)
    }

    private func failAllPromises(_ error: Error) {
        guard !promises.isEmpty else { return }
        let pending = promises
        promises.removeAll()
        for (_, promise) in pending { promise.fail(error) }
    }
}
