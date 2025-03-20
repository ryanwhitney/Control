extension SSHError {
    func formatError(displayName: String) -> (title: String, message: String) {
        switch self {
        case .authenticationFailed:
            return (
                "Authentication Failed",
                """
                The username or password provided was incorrect.
                Please check your credentials and try again.
                """
            )
        case .connectionFailed(let reason):
            return (
                "Connection Failed",
                """
                \(reason)
                
                Please check that:
                • The computer is turned on
                • You're on the same network
                • Remote Login is enabled in System Settings
                """
            )
        case .timeout:
            return (
                "Connection Timeout",
                """
                The connection to \(displayName) timed out.
                Please check your network connection and ensure the computer is reachable.
                """
            )
        case .channelError(let details):
            return (
                "Connection Error",
                """
                Failed to establish a secure connection with \(displayName).
                Please try again in a few moments.
                
                Technical details: \(details)
                """
            )
        case .channelNotConnected:
            return (
                "Connection Error",
                """
                Could not establish a connection with \(displayName).
                Please ensure Remote Login is enabled and try again.
                """
            )
        case .invalidChannelType:
            return (
                "Connection Error",
                """
                An internal error occurred while connecting to \(displayName).
                Please try again.
                """
            )
        case .noSession:
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