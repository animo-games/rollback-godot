# Time-sync / latency measurement over the live MultiplayerAPI. Wall-clock
# territory — this is transport plumbing, not simulation, so awaits/timers
# are fine here (contrast with RollbackManager's tick loop, which must never
# touch wall-clock time).
#
# Ported from the old singletons/multiplayer_p2p_client.gd time-sync section,
# simplified (no multi-sample handshake, just a steady ping stream) and with
# its unit bug fixed: the old code labeled Time.get_ticks_msec() deltas as
# "latency_us" and then divided by 1000.0 as if converting usec->msec, when
# they were already msec. RTT/offset here are plain milliseconds throughout.
#
# remote_clock_ms ≈ local_clock_ms + offset_ms.
class_name RollbackNetClock
extends Node

## How often (wall-clock seconds) to ping each tracked peer.
@export var ping_interval_sec := 1.0

## Emitted after each processed pong sample for a peer.
signal peer_clock_updated(net_id: int, rtt_ms: float, offset_ms: float)

const _RING_SIZE := 8

var _tracked: Array[int] = []
var _samples: Dictionary = {}  # net_id -> Array[Dictionary{rtt, offset}], newest last, capped at _RING_SIZE
var _rtt_ms: Dictionary = {}  # net_id -> float (published median)
var _offset_ms: Dictionary = {}  # net_id -> float (published median)
var _accum_sec := 0.0


func _process(delta: float) -> void:
	_accum_sec += delta
	if _accum_sec < ping_interval_sec:
		return
	_accum_sec = 0.0
	for net_id in _tracked:
		_ping.rpc_id(net_id, Time.get_ticks_msec())


## Start pinging a peer (its multiplayer engine id).
func track(net_id: int) -> void:
	if not _tracked.has(net_id):
		_tracked.append(net_id)


## Stop pinging a peer and drop its samples.
func untrack(net_id: int) -> void:
	_tracked.erase(net_id)
	_samples.erase(net_id)
	_rtt_ms.erase(net_id)
	_offset_ms.erase(net_id)


## Median measured round-trip time to a peer, in ms. -1.0 if unknown.
func get_rtt_ms(net_id: int) -> float:
	var v: Variant = _rtt_ms.get(net_id)
	return v as float if v is float else -1.0


## Median clock offset to a peer, in ms (remote_clock ≈ local_clock + offset).
## 0.0 if unknown.
func get_offset_ms(net_id: int) -> float:
	var v: Variant = _offset_ms.get(net_id)
	return v as float if v is float else 0.0


## Local clock projected onto the peer's clock, in ms.
func get_synchronized_time_ms(net_id: int) -> int:
	return int(Time.get_ticks_msec() + get_offset_ms(net_id))


# ============================================================================
# RPCs
# ============================================================================


@rpc("any_peer", "call_remote", "reliable")
func _ping(t_orig: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	_pong.rpc_id(sender, t_orig, Time.get_ticks_msec())


@rpc("any_peer", "call_remote", "reliable")
func _pong(t_orig: int, t_remote: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var now := Time.get_ticks_msec()
	var rtt := float(now - t_orig)
	var offset := float(t_remote) + rtt / 2.0 - float(now)

	var ring: Array = _samples.get(sender, [])
	ring.append({"rtt": rtt, "offset": offset})
	if ring.size() > _RING_SIZE:
		ring.pop_front()
	_samples[sender] = ring

	var rtts: Array = []
	var offsets: Array = []
	for sample in ring:
		var s := sample as Dictionary
		rtts.append(s.get("rtt") as float)
		offsets.append(s.get("offset") as float)

	var median_rtt := _median(rtts)
	var median_offset := _median(offsets)
	_rtt_ms[sender] = median_rtt
	_offset_ms[sender] = median_offset
	peer_clock_updated.emit(sender, median_rtt, median_offset)


# ============================================================================
# Helpers
# ============================================================================


static func _median(values: Array) -> float:
	var sorted_values := values.duplicate()
	sorted_values.sort()
	var n := sorted_values.size()
	if n == 0:
		return 0.0
	var mid := n / 2
	if n % 2 == 1:
		return sorted_values[mid] as float
	return ((sorted_values[mid - 1] as float) + (sorted_values[mid] as float)) / 2.0
