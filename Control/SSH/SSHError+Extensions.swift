extension SSHError {
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
