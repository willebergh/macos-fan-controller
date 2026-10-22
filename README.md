# FanControl

A small, native macOS menu-bar app for personal use on Apple Silicon:

- Current fan RPM (each fan on multi-fan Macs)
- Current CPU, GPU and SoC temperatures where available
- One manual percentage slider, applied to all fans
- **Back to system default**

No curves, background launch service, network access, or third-party dependencies.

## Build and run

Requires macOS 14+ and Xcode's Swift toolchain.

```sh
./scripts/build.sh
open build/FanControl.app
```

The app has no Dock icon. Its menu-bar label shows CPU temperature over actual
fan RPM, using a native macOS dropdown menu and native slider. You can copy
`build/FanControl.app` to Applications or your other Mac. The default build targets
Apple Silicon when built on an Apple Silicon machine.

Reading sensors does not require administrator access. Moving the slider asks for
administrator authorization to run a narrowly scoped helper. No password is stored;
enter it only in the macOS authorization dialog. Authorization is reused while the app stays open, including after a return to
system mode. The helper tracks authenticated clients' kernel-reported process IDs
rather than expiring an active session. Closing the app lets the temporary helper
exit; no helper is installed permanently. An updated helper may require one new
authorization.

The slider is **percent of maximum RPM**, clamped to each fan's hardware minimum.
On the development M4 mini the reported limits are 1,000–4,900 RPM, so 50% requests
2,450 RPM and 0% requests 1,000 RPM (not fan stop). RPM takes time to settle.

## Agent access: stdio MCP

The same native Swift executable provides a dependency-free MCP server. Build the
signed app with `./scripts/build.sh`, then configure your MCP client (replace the
absolute path):

```json
{
  "mcpServers": {
    "fancontrol": {
      "command": "/absolute/path/to/build/FanControl.app/Contents/MacOS/FanControl",
      "args": ["--mcp"]
    }
  }
}
```

Run the executable directly, **not** through `open` or `swift run`: MCP needs its
stdin/stdout attached, and privileged writes require the signed `.app` bundle.
No Node, Python, HTTP listener, or separately installed service is needed.

Tools:

- `get_status {}`: fan RPM, hardware limits/mode, available temperatures, whether
  this MCP connection owns manual control, and any background control error.
- `set_fan_percent {"percent": 84}`: request 0–100% of maximum RPM, clamped to each
  fan's minimum. Acceptance is not proof of measured RPM; the server checks fan
  response in the background and reports failures through `get_status`.
- `restore_system {}`: restore and verify system control. This explicit command
  can also end the menu-bar app's manual override.

Reads need no authorization. Writes use the existing narrowly scoped helper and
may display a macOS administrator dialog; approve it locally, never send a password
through MCP. An updated helper may require fresh authorization. Only grant these
write tools to agents you trust: there is no app-level temperature cutoff.

The MCP process maintains a heartbeat every two seconds, even while stdin is idle.
Manual control lasts for the **connection**, not one tool call. Closing stdin attempts
to release only that connection's manual lease; a stale connection cannot reset a
new owner's override. On a crash/forced stop, the helper attempts system recovery
within 10 seconds without a heartbeat. Failed resets are retried. Keep the server
running for as long as its override is wanted. The menu-bar app and MCP server have
separate leases; another instance's active override makes a manual request fail.
Return to system control in the current owner before switching controllers.

The transport is newline-delimited JSON-RPC 2.0, with initialization, ping,
`tools/list`, and `tools/call`. Protocol versions 2024-11-05, 2025-03-26,
2025-06-18, and 2025-11-25 are supported; stdout contains protocol messages only,
and diagnostics go to stderr. This is a local stdio interface, not a remote server.

## Safety and limitations

AppleSMC is undocumented. This is experimental software, not an Apple-supported
cooling interface. **Readings have been verified on the M4 mini; privileged writes
and M1 MacBook Pro operation still need hardware verification.** Firmware-dependent control is detected at runtime, including optional `Ftst`
unlocking on older Apple Silicon. Unsupported writes produce an error instead of
claiming success. The app verifies actual RPM response, not just accepted targets.

- Positive hardware minimum/maximum RPM limits are enforced and write readback is checked.
  A safe nonzero target must be verified immediately before taking manual ownership,
  including after any firmware-unlock delay.
- Temperatures are display-only: high temperatures and missing/invalid sensors do
  not cancel manual control or restrict the requested percentage. **There is no
  app-level thermal cutoff.** A low manual setting can allow overheating; choose
  an appropriate speed or return to system default.
- A command is shown as waiting until measured RPM responds. An ignored request is
  detected after 10 seconds; a moving fan gets up to 30 seconds to settle. Failed
  response restores system control and shows requested versus measured RPM.
- The app requests system control on its Quit button and before sleep.
- Manual control holds an App Nap exemption while still allowing system sleep.
  Session keepalive never renews a manual-control lease by itself.
- If the app disconnects or crashes, a helper-side watchdog attempts to restore
  system mode after 10 seconds without a manual heartbeat. Failed resets are retried.
- System restoration does not depend on RPM telemetry and revokes the control lease,
  so another instance's heartbeat cannot silently re-enable an override.
- System restoration is verified by mode readback. Failed restoration is shown
  as an error rather than a successful reset.
- These are best-effort safeguards, **not a guarantee**: killing the privileged
  helper, firmware rejection, or OS failure can prevent restoration. Restart the
  Mac if control gets stuck. Never run two fan-control apps simultaneously.
- Sensor names are reverse-engineered. CPU/GPU displays use the hottest available
  sensor from known M1/M4 key candidates, not an official package temperature.
  Unknown hardware falls back to explicitly labeled sensor keys.
- The helper socket allows only the same login user, checks root credentials on
  the client, accepts only fixed control commands, and lives under `/var/run`.
  Authorization stages a private root-owned copy, verifies its signature and digest,
  and matches its code identity to the running app before execution. Temporary copies
  are removed when the helper exits normally. It is still a personal-use prototype,
  not a hardened signed-XPC deployment.

## Development checks

```sh
swift test
swift run FanControl --probe
```

`--probe` is read-only and prints actual sensors, fan limits and mode. Unit tests
cover numeric formats, limits, firmware handoff/unlock, rollback
and actual-RPM response checks using an in-memory transport. They do not exercise
privileged hardware writes.

`build/FanControl.app/Contents/MacOS/FanControl --test-control` explicitly requests
administrator authorization for a brief maximum-cooling test, prints measured RPM,
and then restores and independently verifies system mode. Never run it alongside
another app's active manual override.

The AppleSMC ABI and sensor conventions were cross-checked against
[Stats](https://github.com/exelban/stats) and
[MacFanControl](https://github.com/raminsharifi/MacFanControl).
