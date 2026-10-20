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

## Safety and limitations

AppleSMC is undocumented. This is experimental software, not an Apple-supported
cooling interface. **Readings have been verified on the M4 mini; privileged writes
and M1 MacBook Pro operation still need hardware verification.** Firmware-dependent control is detected at runtime, including optional `Ftst`
unlocking on older Apple Silicon. Unsupported writes produce an error instead of
claiming success. The app verifies actual RPM response, not just accepted targets.

- Positive hardware minimum/maximum RPM limits are enforced and write readback is checked.
  A safe nonzero target must be verified immediately before taking manual ownership,
  including after any firmware-unlock delay.
- Reduced manual speeds are refused at reported temperatures of 95 °C or above.
  **100% maximum cooling remains available when hot.** Valid CPU/GPU telemetry is
  required; once discovered, a failed safety sensor fails closed. These checks are
  separate from display summaries.
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
cover numeric formats, limits, firmware handoff/unlock, rollback, thermal policy
and actual-RPM response checks using an in-memory transport. They do not exercise
privileged hardware writes.

`build/FanControl.app/Contents/MacOS/FanControl --test-control` explicitly requests
administrator authorization for a brief maximum-cooling test, prints measured RPM,
and then restores and independently verifies system mode. Never run it alongside
another app's active manual override.

The AppleSMC ABI and sensor conventions were cross-checked against
[Stats](https://github.com/exelban/stats) and
[MacFanControl](https://github.com/raminsharifi/MacFanControl).
