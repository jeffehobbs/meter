# Meter

A macOS drum machine where the only thing you set is **how many attacks a
measure gets** — and the machine spends them.

Every measure has a fixed budget, in attacks. A director hands that budget out
across nine lanes, and then keeps changing its mind: moving a slice from one lane
to another, leaning the whole distribution up or down the kit, spotlighting a
lane for a few bars, dropping one out entirely. Because the total never changes,
every one of those decisions is zero-sum — the bright lanes can only get busier
if something else goes quiet. That is what keeps the output legible at any
density instead of just filling up.

The sounds are synthesized in the app, from a small modular rack rather than from
samples or an 808 emulation. It also drives external MIDI, with beat clock, so a
Eurorack drum module or a hardware box can be the voice instead.

```
./build.sh            debug build (macOS)
./build.sh run        build and launch
./build.sh release    release build, Developer ID signed
./build.sh ios        build Meter Flow for the simulator
./build.sh ios-run    …and install and launch it
./Tools/check.sh      headless checks: the budget, the director, the rack
```

```
git clone https://github.com/jeffehobbs/meter
git clone https://github.com/jeffehobbs/cadence   # sibling, needed by the iOS target
```

The iOS app depends on [cadence](https://github.com/jeffehobbs/cadence) by path
rather than by URL, so the two want to sit next to each other. The macOS app does
not need it, but `xcodegen` generates both targets at once — so without the
sibling checkout, nothing generates.

A signed and notarized macOS build is on the
[releases page](https://github.com/jeffehobbs/meter/releases).

There are two apps. The Mac one is an instrument; **Meter Flow**, on iOS, is the
same machine with nothing to operate — see [Meter Flow](#meter-flow-ios) below.
`Sources/Shared` is shared between them verbatim: the budget, the director, the
composer, the rack and the transport are all platform-neutral. `Sources/Mac` and
`Sources/iOS` are only the parts that cannot be.

## The idea

Three things decide where a hit goes, and they are deliberately separate:

| what | decides | where it lives |
|---|---|---|
| the **budget** | how many attacks the measure has | you |
| the **director** | how they are divided between lanes | `Composition/Director.swift` |
| the **corpus** | where a lane of that density likes to put them | `Composition/StepAffinity.swift` |
| the **meter** | which steps are strong | `Model/Measure.swift` |

The budget is apportioned by largest remainder, so the parts sum to the total
exactly: **every measure spends all of it**. A lane that is muted or resting has
its share redistributed rather than lost.

A hit costs one attack. A **flam** costs two, because it is two attacks — which
is the whole reason the budget is counted in attacks rather than in notes. When a
lane is allocated more attacks than the measure has steps, the surplus turns into
flams; the lane starts double-striking instead of overflowing.

### Where hits land

The placement prior comes from 214 transcribed drum-machine patterns (Stephen
Handley's transcription of the *260 Drum Machine Patterns* book — the same corpus
Phonotropic sequenced literally). Meter never plays those
patterns. It reads them as statistics: for each lane, at each density, how likely
is a hit on each step. Density matters more than it looks — two kicks in a bar
and nine kicks in a bar do not go in scaled-up versions of the same places — so
the prior is conditioned on the count.

That prior is multiplied by the meter's own accent pattern, raised to a power the
director moves around: at one end hits pile onto strong beats, at the other the
same machinery puts them in the gaps. Odd meters work because the accent pattern
knows that 7/8 is 2+2+3 rather than "seven eighths", and because the corpus prior
is resampled by *phase* through the bar rather than truncated.

Every session opens differently. That sounds obvious and it was not true for a
while: the lane placement streams were seeded from fixed constants and the
measure index, and the director's opening distribution was fixed too, so every
launch played an identical first three measures before the gestures had moved
anything. Now the session seed reaches both — the opening kit is the seed
distribution leaned on a little differently each time — and `Tools/check.sh`
asserts that two sessions do not open on the same bar, and that one seed still
reproduces one piece of music.

Each lane also keeps some of what it played last measure (the **Drift** knob is
how much it forgets), so a measure is an edit of the one before rather than a
stranger. Repulsion keeps hits from clumping, relaxing as a lane gets busy
because "don't sit next to anything" is unsatisfiable at fourteen hits in
sixteen steps.

### Why it never settles

Two rules are inherited from [Thrum](https://github.com/jeffehobbs/thrum)'s Flow director, and they are the
difference between this and a randomizer:

- **Nothing is ever set, only ramped.** A share that jumps between two measures
  is an event the ear catches. The same move spread over four to ten measures on
  a smootherstep — zero velocity *and* zero acceleration at both ends — is just
  the music going somewhere.
- **Every gesture runs on its own prime clock.** Transfers every 5 measures,
  tilts every 7, spotlights every 11, dropouts every 13, placement churn every
  17, on-beat/off-beat shifts every 19, repatching every 29. Nothing lines up, so
  nothing is ever a section. (The prime idea comes from [Echo](https://github.com/jeffehobbs/echo), where
  every phrase recurs on a prime number of beats.)

### What drifts

Nothing in the machine sits still for an hour. Each of these moves on its own
prime clock, on a ramp, within a range narrow enough that no single change is an
event:

| | range | roughly |
|---|---|---|
| lane shares | zero-sum | transfers, tilts, spotlights, dropouts |
| placement bias | on ↔ off the beat | every 19 measures |
| patches | any of 16 | every 29, always into a quiet lane |
| tone / fold / grit / decay | narrow, per lane | every 3 |
| pan | −0.85 … 0.85 | the slowest gesture in the app |

**What deliberately does not drift is anything that decides *when* a sound
happens.** For a while the director also moved swing, humanizing, how much of
last measure survived, the flam rate, the spread of the budget, and both the
depth and the subdivision of the echo. Individually each was defensible; together
they made an instrument whose timing you could not trust — which is a different
and much worse thing than an instrument that evolves. The line is now explicit:
**the director changes what things sound like, never when they happen.**

The room does not drift either, for the same reason it never did: it is the space
the kit lives in, and a space that keeps changing size is not a space.

**Motion** scales both how often the director decides and how far it moves.
**Spread** bends the weights before they are normalized, so the same allocation
can read as "one lane carries this" or "everybody plays a little".

The director's decisions are printed in the interface. That is not decoration: a
machine that reallocates silently is indistinguishable from one that is broken.

## The rack

Nine lanes, each holding one **patch** — a complete modular percussion voice
described as the settings of a small fixed rack, not as a named drum:

1. **Two oscillators** — carrier and modulator at an arbitrary (usually
   inharmonic) ratio, phase-modulating with an index that has its own fast decay.
   That collapsing index is where the attack comes from.
2. **Pitch envelope** — the carrier starts above its base pitch and falls. The
   classic thump.
3. **Wavefolder** — `sin(g·x)` with the gain riding the body envelope, so the
   harmonics collapse inward as the hit dies.
4. **Ring modulator** — turns a tuned voice clangorous without touching its
   envelope.
5. **Noise channel** — white noise, optionally sample-and-hold crushed, through a
   resonant state-variable filter with its own cutoff sweep. An impulse into a
   high-resonance filter is a **struck filter** — a ping with no oscillator in it.
6. **Inharmonic bank** — six sine partials at non-integer ratios. Metal.

Sixteen patches ship: Thump, Sub, Iterate, Fold, Clang, Muffle, Tine, Zap, Ping,
Clave, Rumble, Grit, Static, Wash, Metal, Shatter. Any lane can hold any of them, and
**Repatch everything** builds a new rack in one gesture.

Four macros per lane — Tone, Fold, Grit, Decay — and that is on purpose: a rack
with a hundred knobs is not playable. With *evolve rack* armed, the director
drifts those macros slowly and repatches a lane now and then, always one that is
currently quiet, so the new sound arrives under the music instead of announcing
itself.

Velocity is not only level. A harder hit gets more modulation index, more fold
and a higher filter sweep, because that is what hitting a real voice harder does.

### The kit is in a room

Each lane renders to **its own mono bus** and is placed in three dimensions by an
`AVAudioEnvironmentNode` — the low lane centred and close, the toms sweeping
across, the bright lanes out to the sides and slightly up. On headphones, and on
AirPods in particular, that is a real binaural render: the kit occupies a room
rather than a line between two speakers. On a loudspeaker the same graph collapses
to ordinary panning, because the rendering algorithm is `.auto` and asking for
HRTF into a speaker is how a mix ends up thin and far away. A lane's Pan control
slides it along x from its place in the kit.

Each lane renders **independently**, and that is load-bearing rather than
incidental. The first version rendered all nine lanes in whichever callback came
first each cycle and let the other eight copy their share out of a shared buffer.
That is correct only if every source node is pulled once per cycle with the same
frame count — which is true on a Mac and **false on a phone**, where the engine
inserts a format converter in front of each input to the 3D mixer and each
converter pulls its source on its own schedule. The result was nine lanes each
holding a different moment in time and a sequencer advancing several times per
cycle: meters full of signal, and nothing recognisable to listen to. A lane's
voices touch no state but their own, so there was never anything to coordinate.

Nine buses summing after the kernel changes the gain staging, and the numbers are
measured rather than guessed (`Tools/check.sh`): each lane leaves a lot of
headroom, nine of them landing on a downbeat is a much bigger peak than its
loudness suggests, the level comes back as 9 dB of pre-gain in front of the
limiter, and a final trim leaves about a decibel under full scale — because the
peak limiter's own ceiling *is* 0 dBFS, and a hit that lands on digital zero is a
converter overshoot waiting to happen.

A cymbal that measures quieter than the kick can still dominate a mix, and the
mechanism is duration rather than level. `Metal` peaked below `Thump` and rang
for **1.1 seconds** against the kick's 0.3 — so it was always present while the
drums were only sometimes, and it overlapped itself. It is half as long now
(0.55 s), its partials roll off more steeply because the upper ones sit in the
two-to-four kilohertz band the ear is most sensitive to, and the bright lanes
come in under the drums in the kit's default balance — the way a drummer sets up
a kit rather than the way a synthesiser defaults.

Nothing in the bank is allowed to be a *note*. Three ceilings enforce it, and
they exist because the first attempt only capped one of the three places a pitch
can come from: a tuned body (270 Hz, roughly middle C), a **struck filter's**
centre frequency (1.1 kHz — a resonant filter's cutoff *is* its note), and an
**inharmonic bank's** base (700 Hz, where its partials start).

`Tools/check.sh` measures this rather than trusting it. For each patch it takes
the tail — everything after the first sixty milliseconds, since a hit's attack is
broadband by definition — and asks how much of it is a single frequency, as a
ratio of the loudest partial to the mean of the spectrum. A drum comes out at a
few hundred times at 50–260 Hz. `Clave` came out at **1582 Hz, 1390×, ringing for
a fifth of a second**, which is the arithmetic of a beep and was audible across a
room as exactly that. It is a click with a pitch now rather than a pitch with a
click.

Not every patch should be a foreground sound. `Muffle` exists because the bank
had nothing that sits *under* the music — the mid lane had shipped with `Ping`, a
high-Q struck filter, which is an opinion rather than a part.

The lane names (Low, Body, Edge, Tom I–III, Tick, Sustain, Air) are *positions in
a kit*, not promises about a sound. They are what let the corpus, the MIDI note
map and the budget's low→high axis line up.

## Time

Ticks at 96 PPQN. Steps, swing, humanized micro-timing and flams are all tick
offsets, and MIDI beat clock falls out of the same counter at every fourth tick —
24 PPQN, exactly as specified. Composing at a coarser resolution and bolting on a
separate clock generator is the arrangement that drifts out of step after ten
minutes.

Meters: 4/4, 3/4, 5/4, 7/4, 5/8, 6/8, 7/8, 9/8, 11/8, 12/8 — and, when the bar
is allowed to move, meters nobody wrote down.

## Moving the bar

A meter change is the one gesture in the app that **cannot be ramped**.
Everything else the director does is a slide: a share, a macro, a tempo. The bar
is either sixteen steps long or it is twenty, and there is no halfway. So the
question is not how to smooth it but where to hide it, and the **moves** picker is
six different answers, exactly one running at a time. It ships as `fixed`.

| moves | what it does |
|---|---|
| `fixed` | nothing. The bar is what you set. |
| `sections` | pick a new meter outright, at the thinnest part of a passage. |
| `pivot` | 4/4 ⇄ 4/4 triplet — **same bar length**, other subdivision. |
| `elide` | one bar of 7/8 inside four, then back. |
| `walk` | a meter one **tail edit** away: a beat appended, dropped, relengthened. |
| `rotate` | never changes the meter; the lanes phase against the bar instead. |

`pivot` is the gentlest because it is not really a meter change: sixteen
sixteenths of 24 ticks and twelve triplet-eighths of 32 are both 384 ticks, so the
bar keeps its length and the quarter note never moves. Straight becomes a shuffle
with nothing to catch.

`walk` only ever edits the **last group** of the bar. `[4,4,4,4]` → `[4,4,4,4,4]`
is 4/4 → 5/4 in which the first sixteen steps are literally identical and a beat
is appended; relengthening an interior group would shift everything after it,
which is the kind of change the ear catches. Because every step is that small, a
walk can get a long way from four — eight meters over 1,400 bars in the checks,
including ones the list above does not name.

`rotate` is the only option that *cannot* disrupt the beat, because nothing global
ever changes. Each lane's figure slides a small fixed number of steps per bar, so
the kit phases against itself — and the bass and snare slide by zero, because a
kit in which nothing is where one is does not sound polymetric, it sounds broken.

Two things underneath matter more than the choice between them. A meter change
used to wipe the composer's memory, so nine lanes re-rolled on the same downbeat
— worse than the new bar length, and the real reason it read as an edit. Now the
figure is **remapped by tick**, which is the single rule that covers both kinds of
move: across a pivot the tick is what has to survive, and across a length change
preserving the tick preserves the step index. And the budget is held as **attacks
per bar of 4/4**, scaled to whatever the bar currently is, so a shorter bar does
not arrive wearing a density change as well.

## MIDI

Meter always publishes a virtual source named **Meter Out** that any app can
subscribe to, and can additionally send straight to one chosen destination. Route
is Rack / MIDI / Both. The note map starts at General MIDI and is editable per
lane, because a Eurorack drum module rarely follows GM. Notes get a real 30 ms
gate, and the app sends note-offs on stop and on quit — an external instrument is
never left holding a note.

## Checks

`./Tools/check.sh` compiles the engine without the interface and exercises it:

- every measure spends its budget exactly, at budgets 1 → 64 and in all ten
  meters, with nothing off the grid, doubled, or over a lane's cap;
- **how much a meter change costs**, per option above: what fraction of the figure
  survives a bar line where the meter moved, against an ordinary bar line. A ratio
  of 1.0 means the change is indistinguishable from any other bar. `sections`
  scores 0.17 and is in there as the thing to beat; `walk` scores 0.96. The same
  section checks that a pivot needs no density correction at all, that a walk only
  ever edits the tail, and that rotation moves the kit somewhere else while keeping
  the same figure when it gets there;
- the distribution actually walks (peak total-variation ≈ 0.6 over 300 measures),
  every lane gets used, and at rest the director both decides less often and
  moves less far per measure;
- every patch makes a sound, is quieter when hit softer, leaves no DC, and ends;
- and a real measure rendered through the room and the limiter peaks at −2.8,
  −1.7 and −1.1 dBFS at budgets 6, 14 and 48, with zero clipped samples.

`Tools/live/` is the other half: `check.sh` renders the graph *offline*, through
manual rendering, and a graph can measure perfectly there and be silent in real
time — different thread, different puller. The live tool starts the engine for
real, plays a bar and taps the mixer to see whether anything came out.

Three real bugs came out of writing those checks, all of which were inaudible in
theory and obvious in measurement: the struck-filter patches were 50 dB down
because a single-sample impulse into a resonant filter carries almost no energy;
`Static` was a sample-and-hold fighting a 10 kHz highpass and cancelling itself;
and Motion scaled only *how often* the director moved, not *how far*, so a calm
session drifted further than a restless one. A fourth turned up when the fixed
patches made everything louder: a full-budget measure reached exactly digital
full scale, which is why the rack's ceiling now leaves a decibel of headroom.

## Notes

- The interface draws the step grid, the lamps and the allocation bar in
  `Canvas`. As nested stacks, laying out 144 cells at the rate the playhead moves
  cost several times more processor time than every voice in the rack put
  together (57% → 16% of a core, measured with `sample`).
- The playhead, the level meter and the lane lamps live on separate observable
  objects from everything else. Anything that reads a published property is
  re-evaluated when *any* property of that object changes, so a level meter
  sharing an object with the step index means the whole window is laid out at the
  meter's rate.
- Not sandboxed, deliberately: CoreMIDI endpoints and an audio output unit are
  not restricted resources, the only persisted state is `UserDefaults`, and the
  sandbox gets in the way of talking to a class-compliant USB drum machine.
- Tempo and budget are yours. The director never touches either.
- **Reseed allocation** (⌘R) puts the distribution back to the starting kit and
  leaves everything else alone. **Reset everything to factory defaults** (Machine
  menu, or the button under the controls) puts every control, the whole rack and
  the stored state back to how the app shipped.
- Explanations live in tooltips rather than printed under the controls, and the
  wordmark has no tagline under it.
- The app icon is drawn by `Tools/icon.py`. It has a transparent background on
  purpose: recent macOS composites a legacy icns onto a plate of its own, so any
  background we draw ends up as a second rectangle sitting on the system's. And
  the Info.plist needs `CFBundleIconName` as well as `CFBundleIconFile` — without
  it the asset catalog compiles an icon that never reaches the Dock.


## Flow (macOS)

⌘F, or the **flow** pill next to the tempo and budget sliders.

The director already decides everything about *how* a measure is played. Two
numbers were always the player's — tempo and budget — and Flow is what happens
when you hand those over too and leave the room. It moves them on long arcs:
tempo within ±14% of wherever you left it, over four to ten minutes; budget in
passages, thin then busy, so a session has a shape rather than a level. Measured
over four hundred measures the biggest single-measure step is **1.2 bpm** — a
change you can catch happening is a change that failed.

Flow no longer touches the **meter**. That is its own switch now — see
[Moving the bar](#moving-the-bar) — because a meter change is not a slow arc and
does not belong with the two that are.

A hand on either slider **re-centres** Flow rather than fighting it — your number
becomes the new anchor. And Flow deliberately leaves alone everything that
decides where a hit lands inside the bar: a slow arc in tempo is a piece
breathing, a drifting swing is a fault.

## Meter Flow (iOS)

The phone build is for leaving on. One ring, one knob, and a tempo that would
rather come from your pulse than from a slider.

The ring is the allocation bar bent into a circle: the outer band is who
currently holds the budget, the inner ticks are the attacks this measure actually
spent, and the lamp goes round once a bar. The knob is density. Everything else —
which lanes, which patches, when to reallocate — the director was already
deciding on its own, so on a phone it simply gets on with it.

**Tempo follows your pulse**, through [Cadence](https://github.com/jeffehobbs/cadence), a package built
alongside this app and meant for the other iOS apps too. A phone has no
heart-rate sensor and most listening happens with no watch on, so Cadence uses a
real measurement when there is one and extrapolates from pace, movement,
climbing, effort and time of day when there is not — and gets better at it as it
sees more of you. The heart button opens its tuning screen: read the number off
your watch, type it in, and that reading is both an answer and a lesson. Turn
*Follow my pulse* off and the tempo is a slider again.

The spatial field is the same one the Mac app uses, and it is most of the reason
this build is worth having on AirPods.

It is **not head-tracked**, and that was tried and removed rather than never
attempted. A full CoreMotion tracker went in — quaternions throughout, tilt from
gravity with only the twist referenced against a leaky heading, late samples eased
in so a stall could not jump the field — and it worked exactly as designed and
sounded wrong. A kit that stays nailed to the room while you move your head is a
lovely idea for a drone and an unhelpful one for percussion, where the thing you
want is a stable image in front of you rather than a room you are walking around
in. The field is head-locked, and better for it.

It keeps playing with the screen off (`UIBackgroundModes: audio`), appears on the
lock screen with working transport, and has a sleep timer that fades out over
twelve seconds rather than stopping — the point of a sleep timer being that
nobody notices it happening.

Under the play button it says **where the sound is going and whether there is
any** — the output device, the system route picker, and a live level. That is
not decoration, and it comes from a real bug.

Meter used to activate its audio session in `init`, which is to say the moment
the app was *opened* rather than when it was asked for a sound. Two things follow
from that, and both were reported as "no audio". Other apps stopped playing,
because a `.playback` session that is active takes the audio whether or not it is
using it. And activating a session makes iOS re-evaluate the route, so the sound
moved to whatever Bluetooth device happened to be connected — a pair of AirPods
on a desk, in this case — and stayed there for everything else too, because the
session was never given back.

So: the category is declared at launch (which is what lets the engine read the
right hardware sample rate) and the session is **activated on play and released
on pause**, with `.notifyOthersOnDeactivation` so whatever was playing before
resumes. The route picker is there because an app that plays into whatever the
phone last connected to needs a way to say "not there, here".

That fix then caused a second one, which is worth writing down because it is not
obvious and the symptom was identical. Releasing the session on pause leaves a
*paused* `AVAudioEngine` holding a stale IO unit: starting it again succeeds,
reports `isRunning`, renders happily — into nothing. Pausing therefore stops the
engine outright, and playing **restarts** it rather than resuming it. And because
Bluetooth negotiates its own sample rate, the graph is **rebuilt** whenever the
hardware rate moves under it — a source node's format is fixed when it is made,
so a rate change means new nodes, not just new connections.

Three defences, in order of how loudly they fail:

- Activation is checked. If another app refuses to be interrupted, playback does
  not start pretending to — it says so and retries once, half a second later.
- If the transport thinks it is playing and the engine has stopped, the meter
  tick restarts it.
- If the rack is producing samples and **nothing is leaving the mixer** for two
  seconds, the session is re-activated and the engine rebuilt. That is the
  signature of a graph talking to a dead IO unit, and it is otherwise silent in
  every sense.

`METER_CYCLE=1` plays, pauses and plays again on its own, reporting what each
step measured — the two-tap sequence a person performs and a simulator cannot.

And when the meters insist everything is fine and the room is still silent,
`METER_TONE=1` plays a sine through the smallest possible graph, and
`METER_PROBE=1` plays one through the 3D node and then straight to the mixer, an
octave apart so the answer cannot be ambiguous. Between them they cut the problem
in half twice: the tone proved the session, the route and the AirPods were fine;
the probe cleared the spatial stage; what was left was the one assumption the
render callback made, and the graph dump (`AVAudioEngine.description`, logged by
`dumpGraph()`) showed the converters that broke it.

The lesson worth keeping: **every level meter in this app measured the broken
version as healthy.** The rack was producing samples, the mixer was passing them,
the peaks were sensible. What no meter could see was that the samples were nine
different moments stitched together. When instrumentation says a thing works and
a person says it doesn't, the person is right and the instrument is answering a
different question.

**Triple-tap anywhere to mark a moment.** It writes everything the machine is
doing to a file on the phone — tempo and where it came from, route, output level,
head tracking, your estimated pulse, the global effects, a per-lane table of
which parameters belong to which drum, and the last twelve measures with their
hit counts and the director decisions that fired. `./build.sh log` pulls it off.

The window is retroactive on purpose, which is Thrum's lesson: by the time
somebody has heard something, decided it was worth marking and got a thumb to the
screen, several seconds have gone, so a snapshot of only the instant of the press
points at the wrong bar. Undiscoverable on purpose too — a diagnostic, not a
feature, and three taps rather than two because the screen is covered in one-tap
targets and a false mark is a lie in the log.

Three debug affordances. `METER_AUTOPLAY=1` starts it at launch and
`METER_TUNING=1` opens the pulse screen — the simulator has no way to tap
anything — and either of those, or `METER_DEBUG=1`, also prints the audio
diagnostics to stdout:

```
./build.sh device
xcrun devicectl device process launch --device <id> --console \
  -e '{"METER_AUTOPLAY":"1"}' com.jeffhobbs.meterflow
```

which answers the only question worth asking when an audio app is silent — is it
rendering, and is anything leaving the graph:

```
session active — 48000.0Hz, out AirPods Pro 2 [BluetoothA2DPOutput], vol 0.8
engine started — out 48000.0Hz 2ch, env 48000.0Hz 2ch, lanes 9
six seconds in: running true, cycles 390, synthPeak 0.86, OUTPUT 0.84, mixer 1.0, trim 0.89
```

`synthPeak` is what the rack produced; `OUTPUT` is what left the mixer. The two
disagreeing is the diagnosis.

`./build.sh device` builds, signs and installs it on a paired iPhone.
`-allowProvisioningUpdates` is what registers the App ID and turns on the
capabilities the entitlements file asks for — HealthKit here, which is a free
capability and needs no review. If it were not enabled the failure would read
`Entitlement com.apple.developer.healthkit not found and could not be included in
profile`, which sounds like a typo and is not.
