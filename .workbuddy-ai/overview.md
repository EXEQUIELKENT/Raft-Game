# Raft Rumble — five fixes applied

All five changes are in the codebase at `C:\xampp\htdocs\Raft-Game`. Verified with
`flutter analyze` (0 errors, 0 warnings) and `flutter test` (53/53 passing).

## 1. Blind-fire camera — no more free rangefinder

**The bug:** aiming eased the camera toward `world.landingX(...)`, so the drag walked the
view across to the enemy raft and showed exactly where the shot would land.

**The fix:** the camera now belongs to the shooter. It is clamped as a *signed lead* over
their own raft, with two hard limits:

- **Near end** — the shooter always stays in frame (130-unit margin).
- **Far end** — every *living* enemy is held outside the frame (90-unit clearance).

The dotted trajectory preview is capped at 34 % of the flight, so the arc reads as a
shape hint (like the Friv original) rather than a rangefinder. A projectile is followed
only as far as the shooter's own water, then it arcs out of frame.

Two details worth knowing:

- Clamping an absolute centre-x does **not** work — an incoming shot then drags the view
  clean off the shooter's own deck. The lead-relative clamp is what makes both ends hold.
- `camOverhang = 420` lets the camera pan slightly past the world edges. Without it an
  ultrawide monitor (≈1500 world units of visible width) could not hide a raft sitting at
  x = 1500, because the old camera was floored at 0.

## 2. Raft spacing

| | before | after |
|---|---|---|
| world width | 2100 | 3210 |
| player x | 152 | 210 |
| enemy slots | 760 / 1120 / 1480 / 1830 | 1500 / 1900 / 2300 / 2700 |
| velocity scale | 0.24 | 0.32 |

Gap between the two rafts is now >900 units of open water. The velocity scale went up with
it so the far raft stays reachable — verified by sweeping the whole legal (angle, power)
envelope; the best shot lands within ~11 units of the target.

## 3. Ragdoll hits and drowning

Every crew member now has a body — `offset`, `vel`, `tilt`, `spin`. A hit calls `knock()`,
which kicks them back along the impact direction and lifts them off the deck; they tumble,
land, bounce, skid, settle, and shuffle back to their station.

Bodies run on their own fixed 60 Hz accumulator, so both devices in a hotspot match
compute the **identical** result even though they never tick in lockstep.

Going into the water is fatal: feet past the waterline + 14 units sets HP to 0, marks the
crew member `drowned`, and leaves a splash. A raft dies only when its whole crew is gone.

**Measured slide distance by weapon** (tuning target was "an ordinary hit rocks someone
back, only heavy ordnance sweeps them over the side"):

| weapon | force | slide | result |
|---|---|---|---|
| tennis | 1.76 | 6 | stays aboard |
| cluster | 1.97 | 6 | stays aboard |
| grenade | 2.33 | 8 | stays aboard |
| bomb | 3.02 | 14 | stays aboard |
| anchor | 3.66 | 21–45 | **overboard** on a tight deck |

An earlier, punchier version of these numbers threw someone overboard on *every* hit.

## 4. Windows desktop

`flutter create --platforms=windows` plus:

- `windows/runner/` — window titled "Raft Rumble", 1280×720, minimum 960×540.
- `.vscode/launch.json` + `tasks.json` — F5 runs the desktop build.
- `tool/run_windows.ps1` and `tool/build_windows.ps1` — command-line equivalents.
- `lib/game/desktop.dart` — platform shorthands; `main.dart` now guards the orientation
  lock behind `Desktop.isMobile`, since there is no desktop platform channel for it.
- `game_screen.dart` — keyboard controls: arrows/WASD to aim (Shift = coarse),
  Space/Enter to fire, R to rematch, Esc to go back, 1–5 to pick a weapon.

Builds as a real `raft_rumble.exe` (debug and release).

## 5. Hotspot multiplayer — rewritten

**Root cause of the flakiness:** the old transport upgraded an `HttpServer` connection to
a WebSocket. That handshake is the first thing to break on a real hotspot — a carrier NAT,
captive-portal shim, VPN tun interface or OEM power-saving proxy is free to rewrite,
buffer or reject it.

**Replacement** (ported from `C:\xampp\htdocs\Battle-Ship-Blitz-Mobile-Game`):

- Raw TCP `ServerSocket`/`Socket` with newline-delimited JSON. No handshake to break.
  Framing is explicit because TCP is a stream — a `send` can be split across packets or
  coalesced with the next one.
- UDP room beacon + scan, so players tap a room instead of typing a 12-digit IP. Manual
  IP entry remains as a fallback.
- Reports **every** local IP, not just the first — a hotspot phone also holds a
  mobile-data address the joiner cannot reach.
- Two-way `hello` handshake; START is disabled until the guest is actually listening.
- Android `WifiManager.MulticastLock` via `MethodChannel`, with `NEARBY_WIFI_DEVICES` and
  `CHANGE_WIFI_MULTICAST_STATE` in the manifest.
- Turn synchronisation via a sequence token, so an echoed `endTurn` is honoured once and
  only the device whose turn it is runs the countdown.

## Testing

New file `test/blind_fire_and_physics_test.dart` adds 19 tests:

- camera lock holds at every plausible aspect ratio (visible width 200 → 1500), including
  while following a projectile that has already arrived
- arc preview never reaches the enemy at any power
- raft spacing, and that the enemy is still reachable within the legal aiming envelope
- ragdoll kickback, settling, recovery, drowning elimination, raft death, and
  frame-rate independence (120 Hz vs 60 Hz land in the same place)
- `SocketLink` framing over a real loopback socket: split writes, coalesced writes,
  malformed lines, blank lines, and a full handshake round-trip

> **Note for future runs:** `flutter test` fails in this environment unless the proxy is
> bypassed — the shell sets `HTTP_PROXY` to `http://127.0.0.1:12495` and the test harness
> honours it for its own localhost connection. Run:
> `NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" flutter test`
