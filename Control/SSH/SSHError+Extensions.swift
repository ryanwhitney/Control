extension SSHError {
    func formatError(displayName: String) -> (title: String, message: String) {
        switch self {
        case .authenticationFailed:
            return (
                "Authentication Failed",
                """
                The username or password provided was incorrect.\n
                Please check your credentials and try again.
                """
            )
        case .connectionFailed(let reason):
            return (
                "Connection Failed",
                """
                \(reason)
                
                Please check that:\n
                • Both devices are on the same network\n
                • Remote Login is enabled in your Mac's System Settings 
                """
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
                    "Connection Lost",
                    """
                    The connection to \(displayName) was lost.
                    
                    Please check that:
                    • Both devices are still on the same network
                    • Your Mac is awake and responsive
                    • Remote Login is still enabled
                    """
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
