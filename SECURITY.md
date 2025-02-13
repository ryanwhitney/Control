# Security

Control connects to MacOS machines over SSH and is intended to work over a local network.

## Login & Password Storage

There are no credentials for Control itself. Instead, you enter the username and password for an existing user account on the machine you’re trying to connect to.

Control offers “one-tap connect” functionality which saves those credentials on device.

When you choose to save your Mac's password:
- It's stored securely in your iPhone's Keychain
- It's never written to disk in plain text
- It's never sent anywhere except directly to your Mac for SSH authentication

## SSH Security Note

The app currently accepts all SSH host keys without verification. While this is fine for local network use (and makes the initial connection smoother), you should be aware that it means the app won't warn you if the remote machine’s host key changes.

## Permissions

Control needs a few permissions to work:
1. Local network access (to find and connect to your Mac)
2. Automation permissions on your Mac (to control media apps)

These permissions are only used for their intended purpose - controlling media playback.

## Found a Security Issue?

If you find a security vulnerability, please report it by opening a GitHub issue with [SECURITY] in the title or contacting the support address at https://rw.is/control

