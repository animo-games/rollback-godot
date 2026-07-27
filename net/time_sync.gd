## Frame-advantage / timescale-nudge math for RollbackNetSession, factored out
## of the session God-object. Tracks a rolling frame-advantage estimate built
## from the adv values piggybacked on every input packet, and decides when the
## session should sleep a single physics frame to bleed off a lead over its
## remote (a mild slow-mo that keeps the two sims from outrunning what rollback
## can absorb).
##
## Seam with the session: this helper computes the *decision* only. The session
## still owns applying it — shifting its physics-frame epoch (_tick_epoch_frames)
## when should_sleep_frame() returns true — because the epoch is entangled with
## throttle re-anchoring the session must keep. Throttle DETECTION (the
## wall-clock inter-frame gap) also stays in the session; on a throttle it calls
## reset() here to drop the now-meaningless samples and nudge accumulator.
extends RefCounted

## Proportional-drip nudge tuning: NUDGE_GAIN converts a tick-lead into a
## per-frame sleep-probability accrual rate; NUDGE_MAX_RATE caps that rate so
## the leader never freezes for more than every other frame.
const NUDGE_GAIN := 0.1
const NUDGE_MAX_RATE := 0.5

## Newest frame-advantage value the remote reported (from its input packets).
var remote_adv := 0.0
## This peer's smoothed advantage over the shared midpoint (mean of samples).
var local_adv := 0.0
## Accumulated sleep "probability"; a full unit spends one frame of slowdown.
var nudge_accum := 0.0

var _adv_samples: Array = []    # rolling local frame-advantage samples, cap 16


## Fold one remote input packet's advantage report into the estimate.
## `tick` is the session's current manager tick; `rtt_ms` the measured
## round-trip to the sender (already clamped >= 0 by the caller).
func record_sample(tick: int, pkt_t: int, pkt_adv: float, rtt_ms: float) -> void:
	remote_adv = pkt_adv
	var rtt_ticks := rtt_ms * (1.0 / RollbackManager.TICK_DELTA) / 1000.0
	var sample := float(tick) - (float(pkt_t) + rtt_ticks * 0.5)
	_adv_samples.append(sample)
	if _adv_samples.size() > 16:
		_adv_samples.pop_front()
	var sum := 0.0
	for s in _adv_samples:
		sum += s as float
	local_adv = sum / _adv_samples.size()


## Drop stale rolling samples (e.g. the remote peer looks frozen) without
## touching the nudge accumulator.
func clear_samples() -> void:
	_adv_samples.clear()


## Full reset after a local throttle freeze: samples AND nudge are meaningless.
func reset() -> void:
	_adv_samples.clear()
	nudge_accum = 0.0


## Accrue the proportional-drip nudge for this frame and report whether the
## session should sleep one physics frame now. `threshold` is the session's
## nudge_threshold export. Needs >= 8 samples before it will nudge at all.
func should_sleep_frame(threshold: float) -> bool:
	if _adv_samples.size() >= 8:
		var gap := (local_adv - remote_adv) * 0.5
		if gap >= threshold:
			nudge_accum += clampf(gap * NUDGE_GAIN, 0.0, NUDGE_MAX_RATE)
	if nudge_accum >= 1.0:
		nudge_accum -= 1.0
		return true
	return false
