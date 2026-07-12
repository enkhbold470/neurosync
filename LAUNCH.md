# The demo to record

The pitch is not "our focus number goes up." Every neurotech company on earth says that, and the
audience you chose — gamers, per Manifesto VII, *"the hardest, most honest customers alive, they'll
call a fake signal in milliseconds"* — has been lied to by all of them.

The pitch is: **this is the only one that tells you when it doesn't know.**

## The 45 seconds

**0:00–0:12 — The Berger test. This is the whole video.**
Board on. Eyes open, look at the spectrum: broad, flat, no peak. Now close your eyes for ten
seconds. A bump grows in the shaded 8–13 Hz band and the peak snaps to ~10 Hz. Open them: it
collapses.

That is the alpha rhythm Hans Berger discovered in 1929, and it is the single hardest thing in
consumer neurotech to fake convincingly on camera, because it has to appear *at the right
frequency*, *with the right latency*, *only when your eyes are shut*. A `Math.random()` mockup
cannot do it. This is Manifesto II — "if the alpha suppression isn't on the scope, it doesn't
ship" — cashed in as your opening shot.

Say the number out loud: **"that's my alpha, at 10.3 hertz, from one dry electrode behind my ear."**

**0:12–0:22 — Pull the earpad off.**
`NO BIOSIGNAL — 0.31 µV RMS, below the 1.5 µV noise floor. The electrode is not making skin
contact.` The score doesn't drop to zero and it doesn't spike to 100. **It refuses.**

Then say the quiet part: *"An ungated focus score reads an electrode on a desk as flawless
concentration. Ours won't. That's the product."*

**0:22–0:32 — Drop the sample rate to 90 SPS.**
The app refuses again, and prints why: `60 Hz mains folds to 30.0 Hz at 90 SPS and cannot be
notched — directly inside β, the focus numerator.`

This is the flex. You are telling a room full of engineers that you know the exact sample rate
below which your own product becomes a lie, and that you shipped the check. Nobody fakes *that*.

**0:32–0:45 — Put it back on. Calibrate. Work.**
20 seconds of baseline, then the score. Explain what 50 means: *your* baseline, today, in this
session — not comparable to mine, not comparable to yesterday's. Show the honesty block on screen
while you say it, including the jaw-clench caveat.

## Say these, don't dodge them

They are on screen anyway, and volunteering them is what makes the rest credible:

- **One channel, around the ear.** Not Fp1, not frontal, not prefrontal. A proof of concept
  benchmarked against NeuroSky, scaling toward 8.
- **β overlaps jaw and neck EMG.** Clench your teeth and "focus" rises exactly as it does when you
  concentrate. One channel cannot separate them. Demo it on purpose if you're feeling brave.
- **It's β/(α+θ)** — Pope, Bogart & Bartolome, 1995. Not θ/β. Cite it.
- **50 = your own baseline.** The number is not comparable between people.

## Do not say

- ~~8 channels~~ — v4 is `ADS1220_MUX_0_AVSS`: **one** single-ended channel.
- ~~250 Hz / ADS1299~~ — that's v5, which **has never been flashed on real hardware**. v4 ships an
  ADS1220 on a 20/45/90/175/330/600/1000/2000 ladder. There is no 250 on it.
- ~~"Berger validated"~~ — not until there's a real capture. After tonight, if you record the eyes-
  closed bloom, **you will have one.** Then you can say it.
- ~~"-23 min recovery" / "Discord cost you 23 minutes"~~ — that's causation from a confound, and the
  number was invented. Difficulty, fatigue and time-of-day all move focus *and* make you switch
  tabs. Association only.
- ~~Flow Shield muting Slack~~ — a sandboxed macOS app cannot mute another app or pause browser
  tabs. Don't demo a capability that doesn't exist.

## Before you hit record

- [ ] `xcodebuild test -scheme neurosync -destination 'platform=macOS,arch=arm64' -only-testing:neurosyncTests` → 19/19
- [ ] Board charged, on a head, streaming at **175 SPS** (the app's rate picker greys out the rest
      and tells you why)
- [ ] Grant Bluetooth on first Connect (the prompt appears then, not at launch)
- [ ] Whop funnel: verified clear logged-out on 2026-07-12 —
      `whop.com/checkout/plan_6l6R2ntqVSplQ` → 308 → 200, email + Pay, $49.99, no login wall.
      Click it once yourself in a private window anyway; the `/preorder` page uses the *embedded*
      checkout, which is a different code path from the hosted URL that was tested.
- [ ] Audio raw. No BGM.
