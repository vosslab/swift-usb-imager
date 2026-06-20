# UI screenshot review

The four-panel Liquid Glass layout reads as a deliberate, coherent flow:
Source, Target, Flash, Verify left to right, each panel color-keyed (magenta,
blue, teal, green) so the eye tracks the imaging pipeline at a glance. The
primary action ("Choose Image") is unambiguous and anchored at the bottom of
the Source panel. Text over glass is generally legible, and the new red error
badge is the clearest, most intentional-looking element on screen: white icon
and white text on a dense red inset read cleanly and unmistakably as an error.
The main residual concerns are a capture-scale artifact in `error_state.png`
(UI rendered into the top-left quarter of a 2560x1440 canvas), the heavy outer
glow/shadow on the active panel, and a few low-contrast secondary labels.

## Method and limitations

| Item | Detail |
| --- | --- |
| Files reviewed | `main_window.png`, `step2_target.png`, `error_state.png` |
| Canvas size | All three are 2560x1440 PNG (`sips`) |
| Tools used | `sips` for dimensions and region crops, direct image read |
| Tool skipped | No pixel-level color sampler available; opacity and contrast
ratios below are visual estimates, not measured values |
| Coordinate note | Positions are given in the logical 1280x720 render space
unless stated; `error_state.png` content occupies the top-left ~1280x720 of its
2560x1440 canvas (see error-state section) |

## main_window.png

Empty/initial state. All four panels visible, Source panel active (bright
magenta border and glow), Target/Flash/Verify dimmed.

| Observation | Detail |
| --- | --- |
| Panel order and numbering | Numbered badges 1-4 top-left of each panel,
left to right; clear pipeline reading order |
| Primary action | "Choose Image" pill button, bottom of Source panel,
high-contrast light text; obvious primary CTA |
| Empty-state icons | Each panel shows a large outlined glyph plus a caption
("No image selected", "No removable disks found", "Select a target first",
"Waiting for flash"); purpose of each panel is communicated |
| Active vs inactive | Source panel is visibly the active/first step; the
other three are correctly de-emphasized |
| Glass execution | Per-panel tint is the intended identity and works; the
Source panel's outer magenta glow is the heaviest element and edges toward the
double-shadow/over-glow heaviness a glass audit flags |
| Low-contrast text | Caption labels ("No image selected" etc.) are mid-gray
on tinted glass and sit on the low side of comfortable contrast |

## step2_target.png

Source selected (`debian.iso`, 4.3 GB shown in Source panel), Target panel now
active (blue border and glow), Flash/Verify still waiting.

| Observation | Detail |
| --- | --- |
| State progression | Active highlight has moved from Source to Target; the
file chip ("debian.iso" + "4.3 GB") confirms the selection persisted |
| Target panel content | Active blue panel currently shows an empty list area
above "Optional checksum" (no removable disks in this capture); the empty band
is large and a bit barren but matches the empty hardware state |
| File chip legibility | "debian.iso" filename is crisp; "4.3 GB" secondary
line is dimmer but readable |
| Glass execution | Blue active glow is calmer than the magenta Source glow in
`main_window.png`; consistent treatment, slightly less heavy |
| Disclosure control | "Optional checksum" chevron row is clear and correctly
de-emphasized as secondary |

## error_state.png

The new error-badge scene. Three red badges are present: one in the Source
panel (under "No image selected"), one in the Target panel (under "Optional
checksum"), and one in the Verify panel (under "Waiting for flash"). All carry
the same message: "Could not read the source image: the file does not exist or
is not readable."

| Observation | Detail |
| --- | --- |
| Badge legibility | OK. White warning triangle plus white two-line text on a
dense red (~0.82 opacity estimated) rounded inset reads cleanly and crisply at
full resolution; white-on-red contrast is strong |
| Intentional vs broken | Reads as intentional. Rounded-rect inset, padded
icon, consistent corner radius, soft drop shadow; looks like a designed alert,
not a rendering glitch |
| Over-glass contrast | The opaque red fill removes the earlier weak
error-text-over-glass problem; text no longer fights the panel tint. This is
the fix working as intended |
| Badge consistency | All three badges share icon, color, radius, and wording;
consistent component reuse |
| Same-message repetition | The identical "source image" message appears in the
Target and Verify panels, which are about target disks and verification. The
copy is correct for Source but reads as mislabeled/leaked in the other two
panels, since a source-read failure is not naturally a Target or Verify error |
| Capture-scale artifact | The rendered UI occupies only the top-left
~1280x720 of the 2560x1440 PNG; the remaining area is empty. This is a
screenshot capture issue (logical-size window drawn into a 2x canvas without
fitting), not a UI defect, but it makes the file look half-broken at first
glance and should be re-captured for any shared artifact |
| Badge geometry | Target-panel badge sits at roughly x=55..545, y=110..185 in
the 1280-space top-left region; comfortable internal padding, text wraps to two
lines and fills the badge width edge-to-edge in the narrower panels |

## Prioritized UI fixes

| Priority | Issue | Tie-in work package | Suggested fix |
| --- | --- | --- | --- |
| P1 | Same "source image" error text duplicated into Target and Verify
panels where it is contextually wrong | WP-panel-error-render (#10) | Scope the
error message per panel, or only render the source-read error in the Source
panel and show a neutral "blocked upstream" state elsewhere |
| P2 | `error_state.png` UI rendered into top-left quarter of canvas | capture
tooling, not app | Re-capture at correct logical-to-pixel fit so the artifact
is fully framed |
| P3 | Heavy outer glow/shadow on the active panel (magenta strongest) edges
toward glass over-blur/double-shadow heaviness | WP-glass-backdrop (#18) | Tame
backdrop blur and reduce outer glow radius/opacity on the active panel |
| P3 | Per-panel tint is the intended identity but currently leans saturated;
confirm it stays a semantic tint, not decoration | WP-glass-semantic-tint (#17)
| Keep tint tied to step state; verify saturation does not hurt caption
contrast |
| P4 | Secondary caption labels ("No image selected", "Waiting for flash",
"4.3 GB") sit low on contrast over tinted glass | WP-layout-hints (#20) | Nudge
caption color lighter or add a subtle scrim behind empty-state text |
| P4 | Target panel empty list band is large and barren when no disks present
| WP-layout-hints (#20) | Add an explicit empty-state hint inside the list
region rather than only the panel caption |

## Verdict

PASS with follow-ups. The four-panel Liquid Glass layout is coherent, the
primary action is obvious, and the new error badge solidly fixes the weak
error-text-over-glass contrast problem: white-on-dense-red is legible,
unambiguous, and clearly intentional. The one real UI bug is the duplicated
source-image error message appearing in the Target and Verify panels
(WP-panel-error-render). The `error_state.png` half-canvas framing is a capture
artifact to re-shoot, and the active-panel glow heaviness is a known
glass-backdrop refinement, not a blocker.
