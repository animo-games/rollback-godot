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
extends RefCounted

## Callable(is_input: bool, net_id: int, payload: Dictionary) -> void — the
## session-provided dispatch that performs the real .rpc_id() send.
var dispatch: Callable

## Count of input packets dropped by the simulated loss (surfaced in stats).
var dropped := 0

## Test-only: drop the next N outgoing input packets unconditionally;
## deterministic loss for reproducing startup-hole stalls.
var drop_first_inputs := 0

## Ordered input backlog used to reproduce stream head-of-line blocking. While
## held, every later input packet queues behind the first one; after release,
## the whole prefix is dispatched in original order. This differs intentionally
## from latency+jitter simulation, which permits reordering like a datagram path.
var held_inputs := 0

var _queue: Array = []      # delayed sends: payload + {"due", "is_input", "net_id"}
var _ordered_input_backlog: Array = []
var _ordered_input_hold_until_msec := 0
var _rng := RandomNumberGenerator.new()


## Seed the drop/jitter RNG from a wall-clock source. Off the determinism
## boundary, so non-reproducible seeding is intentional.
func randomize() -> void:
	_rng.randomize()


## Begin (or extend) an ordered input hold. A zero/negative duration is a no-op.
func hold_inputs_for(duration_ms: int) -> void:
	if duration_ms <= 0:
		return
	_ordered_input_hold_until_msec = maxi(
		_ordered_input_hold_until_msec, Time.get_ticks_msec() + duration_ms)


## Test helper: end the wall-clock hold now. Packets remain queued until the
## next process(), which makes it possible to assert that a newly queued packet
## cannot overtake the held prefix.
func release_ordered_input_hold() -> void:
	_ordered_input_hold_until_msec = 0


## Route one outgoing packet: dispatch straight through when all knobs are
## zero/off, else drop (input packets only) or enqueue with simulated
## latency+jitter. Jitter reordering the reliable checksum stream is harmless
## — _rpc_checksum is tick-keyed, not order-dependent.
func queue_send(is_input: bool, net_id: int, payload: Dictionary, latency_ms: int, jitter_ms: int, drop_percent: float) -> void:
	if is_input and drop_first_inputs > 0:
		drop_first_inputs -= 1
		dropped += 1
		return

	if is_input and drop_percent > 0.0 and _rng.randf() * 100.0 < drop_percent:
		dropped += 1
		return

	var now := Time.get_ticks_msec()
	# Once a stream-style backlog exists, later input may not overtake it even
	# if the wall-clock hold expired just before this send.
	if is_input and (now < _ordered_input_hold_until_msec or not _ordered_input_backlog.is_empty()):
		var held_entry := payload.duplicate()
		held_entry["due"] = now + latency_ms
		held_entry["is_input"] = true
		held_entry["net_id"] = net_id
		_ordered_input_backlog.append(held_entry)
		held_inputs += 1
		return

	if latency_ms == 0 and jitter_ms == 0 and drop_percent <= 0.0:
		dispatch.call(is_input, net_id, payload)
		return

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
	var now := Time.get_ticks_msec()
	if now >= _ordered_input_hold_until_msec:
		# Stream ordering means a not-yet-due prefix blocks every later entry.
		while not _ordered_input_backlog.is_empty():
			var held := _ordered_input_backlog[0] as Dictionary
			if int(held.get("due", 0)) > now:
				break
			_ordered_input_backlog.pop_front()
			dispatch.call(true, int(held.get("net_id", 0)), held)

	if _queue.is_empty():
		return
	var remaining: Array = []
	for entry_v in _queue:
		var entry := entry_v as Dictionary
		if int(entry.get("due", 0)) > now:
			remaining.append(entry)
			continue
		dispatch.call(entry.get("is_input", false), int(entry.get("net_id", 0)), entry)
	_queue = remaining
