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
                "Couldn't connect to \(displayName)",
                """
                Please check your network connection and ensure both devices are on the same network.
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
