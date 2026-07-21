## Debug net-condition simulator for RollbackNetSession's OUTGOING packets.
## Test/dev only: delays, jitters, and drops packets to emulate latency/loss,
## then hands survivors to a dispatch Callable the session provides (the real
## @rpc call must live on the session Node, so this helper never calls rpc_id
## itself). This sits OFF the determinism boundary — it perturbs transport
## timing, never simulation state — so its wall-clock RNG is fine here even
## though such randomness would never be allowed inside a _network_tick.
##
## The session owns the sim_latency_ms/sim_jitter_ms/sim_drop_percent knobs
## (kept as @export pass-throughs for harnesses) and forwards them into
## queue_send() per call, so this helper stays stateless w.r.t. configuration.
class_name RollbackNetSim
extends RefCounted

## Callable(is_input: bool, net_id: int, payload: Dictionary) -> void — the
## session-provided dispatch that performs the real .rpc_id() send.
var dispatch: Callable

## Count of input packets dropped by the simulated loss (surfaced in stats).
var dropped := 0

var _queue: Array = []      # delayed sends: payload + {"due", "is_input", "net_id"}
var _rng := RandomNumberGenerator.new()


## Seed the drop/jitter RNG from a wall-clock source. Off the determinism
## boundary, so non-reproducible seeding is intentional.
func randomize() -> void:
	_rng.randomize()


## Route one outgoing packet: dispatch straight through when all knobs are
## zero/off, else drop (input packets only) or enqueue with simulated
## latency+jitter. Jitter reordering the reliable checksum stream is harmless
## — _rpc_checksum is tick-keyed, not order-dependent.
func queue_send(is_input: bool, net_id: int, payload: Dictionary, latency_ms: int, jitter_ms: int, drop_percent: float) -> void:
	if latency_ms == 0 and jitter_ms == 0 and drop_percent <= 0.0:
		dispatch.call(is_input, net_id, payload)
		return

	if is_input and drop_percent > 0.0 and _rng.randf() * 100.0 < drop_percent:
		dropped += 1
		return

	var now := Time.get_ticks_msec()
	var jitter := int(_rng.randf_range(-float(jitter_ms), float(jitter_ms)))
	var due := maxi(now, now + latency_ms + jitter)
	var entry := payload.duplicate()
	entry["due"] = due
	entry["is_input"] = is_input
	entry["net_id"] = net_id
	_queue.append(entry)


## Dispatch every packet whose simulated delay has elapsed. Call once per
## frame (from the session's _process).
func process() -> void:
	if _queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	var remaining: Array = []
	for entry_v in _queue:
		var entry := entry_v as Dictionary
		if int(entry.get("due", 0)) > now:
			remaining.append(entry)
			continue
		dispatch.call(entry.get("is_input", false), int(entry.get("net_id", 0)), entry)
	_queue = remaining
