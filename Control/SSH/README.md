# SSH stack overview

```
+-----------------------+          ping / UI state          +-------------------+
|   SSHConnectionManager| <-------------------------------- |     SwiftUI Views |
|  (heartbeats & recon) |                                   +-------------------+
|                       |  delegates cmd/heartbeat
+-----------+-----------+-------------------------------------------+
            |                                                       |
            v                                                       v
+-----------+-----------+                                +----------+-----------+
|       SSHClient       |  maps logical  ->  physical    |  PlatformRegistry   |
|  (single TCP socket)  |  "system"      ->  system      +----------------------+ 
|                       |  "heartbeat"   ->  heartbeat   |   (app metadata)    |
+-----------+-----------+  otherAppId ->  app-0..app-N   +----------------------+ 
            |
            v
+-----------+-----------+
|   ChannelExecutor(s)  |  serial queue  ->  1 interactive AppleScript shell
|  one per physical key |
+-----------+-----------+
            |
            v
+-----------------------+
|  SSH Channel (PTY)    |  `/usr/bin/osascript -i` keeps interpreter alive
+-----------------------+
```

Highlights
-----------
1. **TCP socket** is opened once by `SSHClient` and reused.
2. **ChannelExecutors** guarantee only *one* command at a time on their interactive shell.
3. **Heartbeat** channel is totally isolated from app/system channels so transient script errors don't look like connection loss.
4. `SSHConnectionManager` owns the reconnection logic and dimming/UI state.

File map
--------
- `SSHConnectionManager.swift` – high-level lifecycle, recovery, UI binding.
- `SSHConnectionManager+Heartbeat.swift` – focused heartbeat implementation.
- `SSHClient.swift` – connection bootstrap and executor pool.
- `ChannelExecutor.swift` – queue, timeouts, warm-up.
- `ChannelExecutor+ShellSetup.swift` – PTY + interactive shell boilerplate. 