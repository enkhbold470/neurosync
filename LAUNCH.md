# Vertex — launch script

Read it cold. Short sentences. No adverbs. Let the screen do the proving.

The pitch is not "our focus number goes up." Everyone says that. The pitch is:

> **This is the only one that tells you when it doesn't know.**

---

## The script

**COLD OPEN — 0:00**

> This is one dry electrode. It sits behind your ear.
> No gel. No cap. Nothing on your forehead.
> Watch my spectrum when I close my eyes.

**BERGER — 0:05**

*Eyes closed. Ten seconds. Alpha blooms in the shaded band.*

> That's alpha. [read the Hz off the screen.]
> Hans Berger found it in 1929. It's the oldest result in neuroscience.
> It's also the hardest thing to fake. It has to show up at the right frequency, the moment my
> eyes shut, and die when they open.

*Eyes open. It collapses.*

> That's a brain. Not a loading animation.

**REFUSAL ONE — 0:18**

*Take the earpad off your head.*

> Point three microvolts. That's the noise floor of the chip.
> A detached electrode reads as flawless concentration on an ungated score.
> Ours refuses to give you a number.

**REFUSAL TWO — 0:27**

*Drop the rate to 90 SPS. The app withholds the score and prints why.*

> At ninety samples a second, sixty-hertz wall power folds down to thirty hertz.
> Thirty hertz is inside beta. Beta is the numerator of the focus score.
> Hum reads as concentration, and you cannot notch it out.
> We know the exact sample rate where our own product stops being true. We shipped the check.

**THE SCORE — 0:38**

*Back on. Calibrate.*

> Twenty seconds of baseline. Now the score is live.
> Beta over alpha plus theta. Pope, 1995.
> Not theta over beta — that one goes *up* when you stop paying attention.
> Fifty is my baseline. Not yours. Not yesterday's.
> And it's one channel, so it cannot tell concentration from a clenched jaw. That's on the
> screen too.

**CLOSE — 0:50**

> The gap between what neurotech promises and what it delivers is a graveyard.
> So we built the one that tells you when it doesn't know.
> Vertex. Dry-EEG inserts for gaming headsets. Forty-nine ninety-nine. Ships Q4.
> We're two people. We'd rather ship something true than something impressive.

---

## The thread

**1/** Every focus tracker will give you a score right now — with the sensor sitting on the desk.

We built the one that refuses.

*[video]*

**2/** One dry electrode, behind the ear. Close your eyes, alpha blooms at ~10 Hz.

Berger, 1929. The oldest result in neuroscience and the hardest to fake: right frequency, right
latency, only when your eyes are shut.

**3/** Take it off your head → `NO BIOSIGNAL — 0.3 µV RMS, below the 1.5 µV noise floor.`

A detached electrode collapses α+θ, so the ratio explodes. An ungated score reads that as perfect
concentration. Ours freezes and tells you why.

**4/** Drop to 90 SPS → `SCORE WITHHELD.`

60 Hz mains folds to 30 Hz — inside β, the focus numerator. Hum reads as focus and it cannot be
notched.

We know the rate where our own product stops being true. We shipped the check.

**5/** The metric is β/(α+θ) — Pope, Bogart & Bartolome, 1995. Never θ/β; that rises with
*in*attention.

50 = your own baseline, frozen after 20 s. Not comparable between people.

One channel. β overlaps jaw EMG. It's on the screen.

**6/** Vertex. Dry-EEG inserts for gaming headsets.
$49.99. Ships Q4 2026.

---

## Say these. They're the moat.

Volunteering the limits is what makes everything else believable. They're on screen anyway.

- **One channel, around the ear.** Not Fp1. Not frontal. Not prefrontal.
- **β overlaps jaw and neck EMG.** Clench your teeth and "focus" rises exactly as it does when you
  concentrate. One channel cannot separate them. Demo it on purpose if you're brave.
- **50 is your own baseline**, this session. Not comparable to mine.
- **β/(α+θ)** — Pope, Bogart & Bartolome, 1995. Cite it.

## Never say these

- ~~8 channels~~ — v4 is `ADS1220_MUX_0_AVSS`. **One** single-ended channel.
- ~~250 Hz / ADS1299~~ — that's v5, which **has never been flashed on real hardware**. v4 is an
  ADS1220 on a 20/45/90/175/330/600/1000/2000 ladder. There is no 250 on it.
- ~~"Berger validated"~~ — not until there's a capture. Record the eyes-closed bloom tonight and
  **you will have one.** Then say it.
- ~~"Discord cost you 23 minutes"~~ — causation from a confound, and the number was invented.
  Difficulty and fatigue move focus *and* make you switch tabs. Association only.
- ~~Flow Shield muting Slack~~ — a sandboxed macOS app cannot mute another app or pause browser
  tabs. Don't demo a capability that doesn't exist.

## Pre-flight

- [ ] `xcodebuild test -scheme neurosync -destination 'platform=macOS,arch=arm64' -only-testing:neurosyncTests` → 19/19
- [ ] **Board on a head, streaming, at 175 SPS.** This has never been run against real hardware —
      do it before you record, not on camera.
- [ ] Grant Bluetooth on first Connect (the prompt fires then, not at launch)
- [ ] Whop verified clear logged-out 2026-07-12: `whop.com/checkout/plan_6l6R2ntqVSplQ` → 308 → 200,
      email + Pay, $49.99, no login wall. Click `/preorder` yourself once — it uses the *embedded*
      checkout, a different code path from the hosted URL that was tested.
- [ ] Raw audio. No BGM.
