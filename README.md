
# just_liquid_glass

A form of liquid glass for Flutter: blobby, SDF-merged glass shapes with refraction, blur, tint and shine, plus a flat fallback mode that runs on every backend.

It's entirely vibecoded (Fable 5), but it's been tested and iterated and refined and used, and is probably very stable, given the defensive approach we took. Fable was instructed to learn from other flutter libraries and take an approach that dodges some of flutter's bugs, a standout decision resulting from that was to avoid using intermediate textures so animating blobs wouldn't churn GPU memory. The full list is in [Bugs dodged](#bugs-dodged) below.

We're currently not trying very hard to very closely imitate apple's default config, since they set blur and opacity way too low, which looks tacky and isn't compatible with maintaining good visual contrast, but we'll support it as a default if anyone can be bothered doing the checking and tuning.

Improvements over flutter_liquid_glass:

- It's possible to interpolate to flatness, where you just get a shape, without refraction or shine.

- The blob shapes are quite flexible, they can each have corner radius, a hole, start and end angle, and different colors and opacities (when blobs touch, colors blend smoothly from one to the other).

- Blobs can be animated out by shrinking (see "Animating a blob out" in `GlassBlob`'s docs) without crashing. `flutter_liquid_glass` throws when a shape's layout goes to zero ([whynotmake-it#149](https://github.com/whynotmake-it/flutter_liquid_glass/issues/149), open).

- Shaped bulges can be animated on keypress using distortion and distortionRange parameters

- Shapes can be rotated

- The blobs of a layer implicitly form a clip mask on the child. This turns out to often be the right thing for animated entry shaping the edges of a container.

Non-improvements:

- Doesn't support arbitrary vector paths, your shapes must compose from our round-capped segments of roundrect-toruses and pills, but that's still a lot of shapes.

- Arbitrarily, the number of blobs supported per layer is currently 16.

Flaws that anyone could fix immediately if they wanted to:

- There are currently no widgets that automatically shape the blob to match the child widget, just haven't needed them yet. It would be easy to build those using `GlassLayer`'s recently added `List<GlassBlob> Function(Size size)? blobBuilder` parameter (which is called after layout, once size is known).

- No chromatic aberration. (it could probably be done in just one prompt, mako just didn't want it (it's not actually good!), but would accept it, even as the default setting, if someone else wants to add it)

- Our flat fallback doesn't support the blur. Fixing this would be easy. The reason it isn't in today is that mako kinda firmly recommends using fully opaque blobs on platforms that don't have full glass. Glass is a good way of adding an outline to an otherwise quite indistinct graphical effect. Without that, you probably shouldn't use transparent-blurred substances this much.

- Minor: Blur is applied before refraction instead of after. The ideal is probably apply blur to a varying degree depending on the ray length, but probably nobody is doing that. Fixing this probably wont be feasible until flutter's issues with use of intermediate textures are resolved.

Other features:

- You can *lerp between* apple-style continuous corners and round corners. At full continuity the corner is fitted to Flutter's [`RSuperellipse`](https://api.flutter.dev/flutter/dart-ui/RSuperellipse-class.html) — what `RoundedSuperellipseBorder` paints, and SwiftUI's `.continuous`. It is a fit, not that shape: Impeller builds the corner from a superellipse segment patched with a circular arc, which has no closed-form distance and so can't go in an SDF, so this uses a single superellipse pinned to the same 45° point. It stays within 0.0066 of the corner radius of the real thing, measured against `dart:ui` in `test/rsuperellipse_test.dart`. What that buys you is that a `cornerRadius` here means what it means in a `Container` decoration — the corner's 45° depth is identical to Flutter's, so radii are directly comparable in both directions.

- There's a GlassSwell widget which you can use to make buttons that create a bulge in the glass of the parent when pressed.

**Everything below this line was written by Fable but has been reviewed.**

## Usage

```dart
GlassLayer(
  options: const GlassOptions(
    blendRadius: 32,       // how far apart blobs start fusing
    blurRadius: 6,
    bevelThickness: 16,
    refractionIntensity: 24,
    // childRefractionIntensity: 0, // child content refracts too by default;
                                    // set 0 for a flat child, or any value
                                    // to differ from refractionIntensity
    shineIntensity: 0.4,
    edgeTint: Color(0x26000000), // rim darkening; keeps white-on-white legible
    shadowRadius: 20,            // drop shadow, on by default
    shadowIntensity: 0.15,       // 0 turns it off entirely
    shadowOffset: Offset(0, 2),
  ),
  blobs: [
    // A circle.
    const GlassBlob(
      center: Offset(120, 160),
      radii: Size(70, 70),
      tint: Color(0x33FFFFFF),
    ),
    // A rotated pill.
    const GlassBlob(
      center: Offset(240, 200),
      radii: Size(90, 36),
      rotation: 0.4,
      tint: Color(0x2200E5FF),
    ),
    // A progress-ring arc segment: ring via holeRadius, sweep via angles.
    GlassBlob(
      center: const Offset(180, 320),
      radii: const Size(64, 64),
      holeRadius: 40,
      startAngle: -math.pi / 2,
      endAngle: -math.pi / 2 + math.pi,
      tint: const Color(0x66B388FF),
    ),
  ],
  child: yourContent,
)
```

Call `GlassLayer.precache()` early (e.g. in `main`) if you want the first
frame to include the glass; otherwise the layer renders its child alone
until the shader programs finish loading.

## If you have multiple glass layers, use a shared backdropGroupKey

Backdrop filters are the expensive part of glass. For each one, Impeller ends the current render pass and re-draws the *entire* render target into a fresh one (`Canvas::FlipBackdrop` in `impeller/display_list/canvas.cc`). If you have multiple GlassLayers showing at the same time, you should probably have them use a shared `GlassLayer.backdropGroupKey`. They'll be slightly incorrect where they overlap, but generally not noticeably so, and it will improve performance by a lot.

### Shape model

Each `GlassBlob` is a rounded box with half-extents `radii`, rotated by
`rotation` around `center`:

- `cornerRadius` — corner rounding. The default (`infinity`) clamps to the
  smaller radius, giving a circle or stadium/pill. `0` gives sharp corners.
- `holeRadius` — cuts a circular hole around the center (ring/annulus).
  Default (`-infinity`) means no hole.
- `startAngle` / `endAngle` — clips to an angular sector in the blob's local
  frame (radians from the local +x axis, positive toward +y / clockwise on
  screen). A sweep of `tau` or more disables the clip. When the blob is a
  circular ring segment (circular radii, default corner rounding, and a
  hole), the open ends get circular caps automatically; other sector shapes
  get a hard cut.
- `tint` — the blob color. In glass mode it is mixed over the refracted
  backdrop with strength `tint.a`; in flat mode it is the fill itself.

### Drop shadow

The shadow is the same distance field read on its outside: alpha falls from
`shadowIntensity` a radius inside the silhouette (hidden under the glass) to
half of it at the silhouette to 0 exactly `shadowRadius` out, which is a
blurred edge's profile. So it follows the merged blobby shape — bridges,
distortion bulges, sector cuts — without a second pass, an extra texture, or a
path to build, and it costs one more field evaluation only when
`shadowOffset` is non-zero. It is drawn by the glass pass itself, beneath the
child, and is occluded by the blobs' own coverage, so an offset shadow never
shows through the glass casting it.

Blobs usually reach the edge of their `GlassLayer`, so the shadow is painted
*outside* the layer's bounds — normal for a Flutter shadow, but an ancestor
that clips (a `ClipRect`, an overflowing `Stack`, a scroll viewport) will cut
it. Give the layer room, or set `shadowIntensity: 0`, which also drops the
shadow's padding from every clip the layer takes.

## Modes and platform support

| Mode | What you get | Where it works |
|---|---|---|
| `GlassMode.glass` (default) | Refraction, blur, tint, shine over the backdrop, falling back to flat where unsupported | Everywhere; true glass on Impeller (iOS, Android, macOS) |
| `GlassMode.flat` | The same merged blobby silhouette as a plain tint fill | Everywhere (Skia and Impeller, including web and desktop) |

Requesting `GlassMode.glass` on a backend without support falls back to flat
rather than throwing. Glass mode uses `BackdropFilter` + `ImageFilter.shader`,
which Flutter only supports on Impeller. Flat mode is an ordinary canvas shader and needs no
backdrop access, so it runs on any backend — it is a deliberate design style
of its own (blobby flat color, possibly translucent), not just a degraded
glass.

Backdrop blur is the engine's own downsampled gaussian, composed under the
glass shader (`ImageFilter.compose`), so `blurRadius` can go as wide as you
like at flat cost. This is why the package requires Flutter 3.41 or newer:
composing `ImageFilter.blur` with `ImageFilter.shader` shifted the shader's
coordinate system until
[flutter#170820](https://github.com/flutter/flutter/issues/170820) was fixed
(see [Bugs dodged](#bugs-dodged)).

## Bugs dodged

Each design decision below traces to a bug you can watch another project hitting:

- **No intermediate textures.** `liquid_glass_renderer` rasterizes shape
  geometry into textures, and [documents](https://github.com/whynotmake-it/flutter_liquid_glass/tree/main/packages/liquid_glass_renderer#%EF%B8%8F-limitations)
  memory spikes when animating shapes because Flutter can't dispose those
  textures promptly ([flutter#138627](https://github.com/flutter/flutter/issues/138627));
  the same texture path crashes outright when geometry bounds collapse to
  zero size ([whynotmake-it#149](https://github.com/whynotmake-it/flutter_liquid_glass/issues/149), open).
  Here the blob field is evaluated analytically in the shader — animating
  blobs is just uniform updates, with nothing to allocate or dispose.
- **The layer's origin is passed as a uniform every paint.**
  `FlutterFragCoord()` is anchored to the render target, not the filtered
  layer, so a glass layer that moves within the target evaluates its field
  in the wrong place — typically ending up invisible or warped. That
  symptom class is on file against `liquid_glass_renderer`: glass and
  contents disappearing when scrolled to the bounds
  ([whynotmake-it#124](https://github.com/whynotmake-it/flutter_liquid_glass/issues/124), open)
  and vertical distortion when scrolling to the top of a feed
  ([whynotmake-it#33](https://github.com/whynotmake-it/flutter_liquid_glass/issues/33), open).
- **Fixed-count loops, no `break`.** Flutter's SkSL transpile mishandles
  loop constructs — `FragmentProgram` fails to compile a plain for loop on
  Skia ([flutter#116850](https://github.com/flutter/flutter/issues/116850), open),
  and during this build `break` compiled silently and rendered garbage. The
  blob loops here run all 16 iterations with an `if` guard, pinned by
  `test/sdf_field_test.dart`.
- **Anti-aliasing without `fwidth`.** Derivative built-ins are rejected at
  runtime on web ([flutter#180959](https://github.com/flutter/flutter/issues/180959), open),
  so edge AA uses the analytic field gradient instead — which also keeps
  the edge band a constant ~1.5 physical pixels wherever merges compress
  the field.
- **Unsupported backends downgrade instead of throwing.** Requesting glass
  where `ImageFilter.shader` isn't available silently falls back to flat;
  compare `liquid_glass_renderer` throwing on unsupported render backends
  ([whynotmake-it#12](https://github.com/whynotmake-it/flutter_liquid_glass/issues/12), open).
