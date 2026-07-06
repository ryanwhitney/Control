import Foundation

extension SSHError {
    /// Single connection-error classifier shared by both transports, so the same
    /// network failure maps to the same `SSHError` (and user-facing message)
    /// whether the streaming or the compatibility client hit it.
    static func classify(_ error: Error) -> SSHError {
        if let sshError = error as? SSHError { return sshError }

        let errorString = error.localizedDescription.lowercased()
        let errorTypeName = String(describing: type(of: error))

        if errorString.contains("nioconnectionerror") || errorTypeName.contains("NIOConnectionError") {
            if errorString.contains("connecttimeout") || errorString.contains("timeout") {
                return .timeout
            } else if errorString.contains("dnsaerror") || errorString.contains("dnsaaaerror") {
                return .connectionFailed("Could not find the device on your network")
            } else {
                return .connectionFailed("Network connection failed")
            }
        }

        if errorString.contains("network is unreachable") ||
           errorString.contains("host is unreachable") ||
           errorString.contains("no route to host") ||
           errorString.contains("connection timed out") {
            return .connectionFailed("Network connectivity lost")
        }

        if errorString.contains("dns") ||
           errorString.contains("unknown host") ||
           errorString.contains("nodename nor servname provided") {
            return .connectionFailed("Could not find the device on your network")
        }

        if errorString.contains("auth failed") || errorString.contains("permission denied") {
            return .authenticationFailed
        }

        if let posixError = error as? POSIXError {
            switch posixError.code {
            case .ECONNREFUSED: return .connectionFailed("Remote Login is not enabled")
            case .EHOSTUNREACH: return .connectionFailed("Computer is not reachable")
            case .ETIMEDOUT: return .timeout
            case .ENETUNREACH: return .connectionFailed("Network connectivity lost")
            case .ENOTCONN: return .connectionFailed("Connection was lost")
            default: return .connectionFailed("Network error: \(posixError.localizedDescription)")
            }
        }

        if errorString.contains("connection reset") ||
           errorString.contains("eof") ||
           errorString.contains("broken pipe") {
            return .connectionFailed("Connection was interrupted")
        }

        return .connectionFailed("Could not establish connection")
    }

    /// Single "is the connection gone?" check shared by the manager and both
    /// transports, so a new fatal pattern added here reaches every layer.
    static func isConnectionLoss(_ error: Error) -> Bool {
        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("connection lost") ||
               errorString.contains("eof") ||
               errorString.contains("connection reset") ||
               errorString.contains("broken pipe") ||
               errorString.contains("connection closed") ||
               errorString.contains("tcp shutdown") ||
               errorString.contains("network is unreachable") ||
               errorString.contains("host is unreachable") ||
               errorString.contains("connection timed out") ||
               errorString.contains("no route to host")
    }

    func formatError(displayName: String) -> (title: String, message: String) {
        switch self {
        case .authenticationFailed:
            return (
                "Authentication Failed",
                "The username or password provided was incorrect. Please check your credentials and try again."
            )
        case .connectionFailed(_):
            return (
                "Failed to connect to \(displayName)",
                "Ensure that both devices are on the same network and Remote Login is enabled on your Mac."
            )
        case .timeout:
            return (
                "Connection Timeout",
                """
                The connection to \(displayName) timed out.
                
                Please check that:
                • Both devices are on the same network
                • Remote Login is enabled on your Mac
                • Your Mac isn't sleeping or locked
                """
            )
        case .channelError(let details):
            if details.contains("Connection lost") || details.contains("Invalid heartbeat response") {
                return (
                    "Lost connection to \(displayName)",
                    "Please check that both devices are still on the same network and your Mac is awake and responsive."
                )
            } else {
                return (
                    "Connection Error",
                    """
                    Failed to establish a secure connection with \(displayName).
                    Please try again in a few moments.
                    
                    Technical details: \(details)
                    """
                )
            }
        case .channelNotConnected:
            return (
                "Connection Error",
                """
                Could not establish a connection with \(displayName).
                Please ensure Remote Login is enabled and try again.
                """
            )
        case .invalidChannelType, .noSession:
            return (
                "Connection Error",
                """
                Could not establish an SSH session with \(displayName).
                Please ensure Remote Login is enabled and try again.
                """
            )
        }
    }
} 
