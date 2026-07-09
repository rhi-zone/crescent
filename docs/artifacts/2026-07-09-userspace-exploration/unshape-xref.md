# unshape ↔ crescent cross-reference

Survey basis: unshape's 45 `crates/*` (read each crate's `lib.rs` doc comment +
public surface); crescent's `docs/inventory.md` plus targeted greps of
`lib/*/init.lua` for libraries the inventory names don't disambiguate.

## 1. Coverage overlap

**Noise.** unshape: `unshape-noise` (Perlin/Simplex/Value/Worley 1D/2D/3D,
Fbm combinator, Pink noise, struct-based sample API) plus `unshape-field`
wrapping noise as lazy `Field<Vec2/Vec3, f32>` samplers, plus
`unshape-expr-field` exposing noise as functions callable from a parsed
expression AST, plus a GPU tier in `unshape-gpu` (compute-shader Perlin/
Simplex/FBM texture generation). Four depth tiers on one algorithm family.
crescent: `lib/noise_gen/` (628 lines) — Value/Perlin/Simplex/Worley +
fBm/turbulence/domain-warping/ridged, pure Lua, no field/lazy-sampling
abstraction, no GPU tier, no expression-language hookup. Both are
production-grade at the algorithm level; unshape goes further with the
field/lazy-evaluation layer and multi-backend execution that crescent's
noise lib has no counterpart for.

**Cellular automata.** unshape: `unshape-automata` — 1D elementary CA, 2D
Game of Life with pluggable Moore/VonNeumann neighborhoods, generalized
`CellularAutomaton2D` (arbitrary birth/survive rule sets), Larger-Than-Life,
SmoothLife (continuous-valued CA), HashLife (exponential-speedup sparse
simulation via quadtree memoization), turmites (Langton's-ant generalization).
crescent: `lib/automata_2d/` + `lib/cellular_automata/` (parallel impls per
inventory) cover Game-of-Life variants and 1D Wolfram/2D totalistic rules.
No SmoothLife, no HashLife, no turmite. unshape's CA crate is meaningfully
deeper — HashLife alone is a serious algorithmic investment crescent has no
analog for.

**Particle systems.** unshape: `unshape-particle` — emitter/force/integrator
trait architecture (`PositionProvider`, `VelocityProvider`,
`LifetimeProvider`, `AttributeProvider` composed via `CompositeEmitter`),
pluggable integrators (Euler, semi-implicit Euler), and it composes with
`unshape-field` so any field can act as a force. crescent: `lib/particle/`
(359 lines) — functional but flat; no composable emitter-trait system, no
field-as-force integration. Overlap is real but unshape's is architected for
extension, crescent's is a fixed feature set.

**2D physics / soft body.** unshape: `unshape-physics` (rigid body + cloth +
softbody + constraints + collision, `unshape-spring` (Verlet/spring systems
for rope/cloth/soft bodies, distance constraints), `unshape-fluid` (grid
Eulerian 2D/3D "stable fluids" + SPH 2D/3D). crescent: `lib/physics_2d/`
(466 lines, semi-implicit Euler, AABB/circle, joints) — 2D rigid body only,
no cloth, no soft body, no fluid. This is a real gap even where "overlap"
nominally exists: crescent's rigid-body coverage is present but shallower,
and the cloth/softbody/fluid pieces have no crescent equivalent at all (see
§2).

**Bezier / spline / curve.** unshape: `unshape-curve` (unified `Curve` trait,
Line/QuadBezier/CubicBezier/Arc, arc-length parameterization) +
`unshape-spline` (CatmullRom, BSpline, NURBS curves) — layered so higher
crates (`unshape-vector`, `unshape-rig`) share one curve abstraction.
crescent: `lib/bezier/` (610 lines, 2D/3D Bezier + Catmull-Rom + Hermite) and
`lib/interpolation_curves/`. Functionally similar surface (both do the
common curve types) but crescent has no unifying trait threading curves
through mesh/rig/vector code the way unshape's `Curve` trait does, and no
NURBS curve type (unshape has NURBS curves in `unshape-spline` and NURBS
*surfaces* in `unshape-surface`, which crescent has nothing like).

**L-systems.** unshape: `unshape-lsystem` — string rewriting + 2D/3D turtle
interpreters, segment-to-path conversion, presets. crescent:
`lib/lindenmayer/` — L-systems with turtle graphics + named presets.
Genuinely close parity here; both are production-grade for this narrow
domain.

**Spatial data structures.** unshape: `unshape-spatial` — quadtree, octree,
KD-tree 2D/3D, ball tree 2D/3D, BVH, spatial hash, R-tree, all under one
crate with a shared `Aabb2`/`Aabb3` vocabulary. crescent has the same
structures but scattered across separate top-level libs:
`lib/quadtree/`, `lib/kdtree/`, `lib/spatial_hash/` — inventory shows no
octree, ball tree, BVH, or R-tree equivalent. crescent covers the 2D case
decently; unshape's 3D spatial coverage (octree, BVH, R-tree, 3D KD/ball
trees) has no crescent counterpart.

**Color.** unshape: `unshape-color` — LinearRgb/Hsl/Hsv/Rgba, gradient
interpolation, blend modes. crescent: `lib/color/` (443 lines) +
`lib/color_palette/` + `lib/color_space/`. Comparable depth; crescent
actually has more surface area spread across three libs (palettes,
colorspace conversions) vs unshape's one crate, though unshape's blend-mode
enum integrates directly with its image/motion-graphics crates in a way
crescent's color libs aren't wired into `lib/canvas/` or
`lib/image_processing/`.

**Spectral / FFT.** unshape: `unshape-spectral` — FFT/IFFT 1D+2D, DCT/IDCT,
window functions, pre-allocated workspaces for real-time reuse. crescent:
`lib/dsp/` covers digital signal processing generally; no dedicated
FFT-workspace-reuse abstraction surfaced in the inventory description, and no
DCT/watermarking-oriented 2D block transform. Rough overlap, unclear depth
parity without reading `lib/dsp/` source directly.

**Procedural generation (maze/WFC/networks).** unshape: `unshape-procgen` —
Wave Function Collapse solver (with named tile-adjacency sources and preset
tilesets), four maze algorithms, Wang tiling, road/river network generation.
crescent: nothing comparable found — this is really a gap (see §2), not an
overlap; listed here only because "procedural generation" sounds adjacent
to crescent's `lib/grammar_gen/` (Tracery-style text generation), which is a
different domain (text, not spatial tiles/mazes/roads).

**Image processing.** unshape: `unshape-image` — adjust/bake/channel/
colorspace/composite/distort/dither/effects/expr(-driven pixel ops)/freq
(frequency-domain filters)/glitch/inpaint/kernel/normal-map/pyramid
(mip)/transform, plus a GPU-accelerated tier in `unshape-gpu::image_ops`.
crescent: `lib/image_processing/` (731 lines) + `lib/canvas/` (734 lines,
pixel canvas + PPM/PGM/BMP export). crescent's image processing is real but
narrower — no frequency-domain filter bank, no normal-map generation, no
inpainting, no mip pyramid, no GPU tier, no expression-driven pixel kernel
language. This is the deepest asymmetric overlap in the survey: both
"do image processing" but unshape's crate is substantially wider and has a
compute-backend story crescent's does not.

## 2. Unshape has, crescent doesn't

**3D mesh generation and editing — `unshape-mesh`.** Primitives, halfedge
mesh representation, boolean ops (CSG), bevel, decimation, dual contouring,
marching cubes, geodesic distance, LOD, loft, mirror, morph targets, ambient
occlusion baking, curvature analysis, mesh repair. This is a large,
production-grade 3D geometry kernel. crescent has *no* 3D mesh library of
any kind — no vertex/index buffer type, no CSG, no marching cubes. For an
"entire computer" vision that includes any 3D content (game assets, CAD-ish
tooling, 3D-printable geometry, procedural environments), this is the single
biggest structural gap: everything downstream (rigging, glTF export, voxel
meshing, point cloud generation) assumes a mesh type crescent doesn't have.

**Skeletal animation / rigging — `unshape-rig`.** Bones, skeletons, poses,
vertex skinning (dual-quaternion + linear blend, up to N influences),
IK solvers, animation blending/layering/crossfade, constraints (aim, path),
secondary motion, motion matching, locomotion. No crescent equivalent —
there is no bone/skeleton/pose type anywhere in the inventory.

**glTF import/export — `unshape-gltf`.** Full `.gltf`/`.glb` read/write.
crescent has no 3D interchange format support at all (its format libs are
all 2D/text/binary-wire: PNG, SVG, protobuf, etc.) — no way to get a mesh in
or out of the ecosystem even if one existed.

**Voxels — `unshape-voxel`.** Dense + sparse voxel grids, SDF-to-voxel
conversion, sphere/box brushes, dilate/erode, voxel-to-mesh. No crescent
equivalent.

**Point clouds — `unshape-pointcloud`.** Mesh/SDF sampling (uniform +
Poisson-disc), normal estimation, outlier removal, voxel downsampling, KNN.
No crescent equivalent (crescent's `lib/knn/` does generic KNN but nothing
sits on top of it for point-cloud-specific operations).

**NURBS surfaces — `unshape-surface`.** Full tensor-product NURBS surface
type (sphere/cylinder/torus/cone/bilinear-patch constructors, tessellation
to mesh). No crescent equivalent (crescent has 2D/3D Bezier curves only, no
surface patches of any kind).

**GPU compute — `unshape-gpu` and the `unshape-backend` abstraction.** wgpu
compute-shader execution for field sampling, texture generation, noise, and
image ops, unified behind a `ComputeBackend` trait so CPU/GPU/SIMD backends
are selected by policy (`ExecutionPolicy::Auto` etc.) rather than hardcoded.
crescent has no GPU story anywhere — everything is CPU (with FFI/SIMD tiers
at most). For heavy procedural workloads (noise fields at texture
resolution, particle sims, image filters) this is a real performance-tier
gap, and the `ComputeBackend`/`BackendRegistry`/`ExecutionPolicy`
architecture itself is worth studying independent of GPU (see §4).

**JIT compilation of expression graphs — `unshape-jit` + `unshape-expr-field`
(cranelift feature) + `unshape-audio::jit` + `unshape-audio-codegen`.**
Cranelift-based JIT for scalar/SIMD compilation of field expressions and
audio graphs, classifying nodes as `PureMath` (inlinable/SIMD-able),
`Stateful` (needs Rust callback, e.g. delay lines/filters), or `External`
(noise, transcendentals) — plus a separate `build.rs`-time Rust codegen path
(`unshape-audio-codegen`) that turns a serialized audio graph into a static
Rust struct, eliminating dynamic dispatch entirely. crescent has nothing
that compiles a data-described graph to native code or generates static
source from one; the closest thing is LuaJIT's own tracing JIT, which
operates on Lua control flow, not on a serialized node graph.

**Audio synthesis — `unshape-audio`.** Oscillators, filters, envelopes,
granular synthesis, a full node/wire audio graph, MIDI, physical modeling
synthesis, room/reverb simulation, spatial (3D) audio, spectral processing,
vocoder, percussion synthesis, patch/pattern sequencing. crescent's audio
surface is `lib/midi/` (Standard MIDI File parser/encoder — file format, not
synthesis) and `lib/dsp/` (general signal processing). There is no
oscillator/envelope/filter-graph synthesis engine, no granular synthesis, no
vocoder, no physical modeling. This is a full domain crescent doesn't touch.

**Reaction-diffusion — `unshape-rd`.** Gray-Scott model, presets (coral,
etc.), multi-channel RD, seeding operations. No crescent equivalent (the
CA/automata libs are discrete-state; RD is continuous-field).

**Fluid simulation — `unshape-fluid`.** Eulerian grid-based (stable fluids,
2D+3D) and SPH particle-based (2D+3D) fluid solvers. No crescent equivalent.

**Space colonization — `unshape-space-colonization`.** Attraction-point tree
growth for organic branching (trees, vessels, lightning). No crescent
equivalent (`lib/lindenmayer/` generates branching via string rewriting, a
different algorithm family with different visual character).

**2D motion graphics scene graph — `unshape-motion` + `unshape-motion-fn`.**
Hierarchical layer/scene structure (After-Effects style: transform, opacity,
blend mode, children) with time-based motion functions (spring, oscillate,
wiggle/noise-based, keyframe timelines with per-segment easing, arc-length
path-follow). crescent's `lib/easing/` gives the easing-function primitives
but nothing above it — no scene graph, no keyframe timeline type, no
spring/wiggle motion combinators, no path-follow.

**Instancing/scattering — `unshape-scatter`.** Distributes instances by
grid/random/sphere/poisson/line/circle with jitter, scale/rotation
randomization, and stagger-timing (for staggered animation reveals).
crescent has scattered pieces (poisson-disc sampling likely buried in
`lib/geom/` or similar, not surfaced in inventory) but no dedicated,
composable scatter/instance API.

**Graph execution substrate — `unshape-core` + `unshape-op` +
`unshape-backend` + `unshape-serde` + `unshape-history`.** A full node-graph
runtime: typed `Value`/`GraphValue`, eager and lazy (memoized/cancellable)
evaluators, a dynamic-operation registry with load-time type validation
(`DynOp`/`OpRegistry`/`Pipeline`), graph (de)serialization to JSON/bincode
with a name→type registry for reconstructing trait objects, and dual
undo/redo strategies (snapshot vs. event-sourcing). crescent has graph/DAG
pieces (`lib/taskgraph/`, `lib/workflow/`) and event-sourcing
(`lib/event_sourcing/`) as separate libraries, but nothing unifying them
around one `Value`-typed, serializable, replayable node-graph runtime
purpose-built for procedural-content pipelines. This is infrastructure, not
a leaf feature — see §4, it's the pattern most worth studying.

**Cross-domain data reinterpretation — `unshape-crossdomain` +
`unshape-bytes`.** Deliberate structure-transfer between domains: image →
audio (MetaSynth-style spectral painting), audio → image (spectrogram),
field → vertices/displacement/image, raw byte reinterpretation as
f32/i16/rgba/xy/xyz sample views. crescent has no equivalent — its codec
libraries convert between *serialization* formats, not between *perceptual*
domains (turning a texture into a sound file, or vice versa). This is a
small, cheap, high-leverage crate that's philosophically distinct from
anything in crescent's inventory.

**Projectional editor — `unshape-editor`.** Live dual-projection editing
(typed op-stack sliders + a derived formula/expression view, both driving
the same GPU render, formula edits promote-and-reparse to raw AST). No
direct crescent equivalent; crescent's closest relatives are
`lib/platform/projection_pipeline/` (projects a Lua source file through the
typechecker to TS, a very different "projection") and the general
reactive/widget stack, but nothing that pairs a structured-parameter view
with a live-reparsed textual view of the *same* underlying document.

## 3. Crescent has, unshape doesn't

crescent's scope is far broader than unshape's by design — it is a general
programming ecosystem, not a media-generation substrate. unshape has no
equivalent, at any depth, for: network protocols (HTTP/TLS/DNS/SMTP/IMAP/
WebSocket/git/GitHub), serialization/codec formats (JSON/CBOR/protobuf/
BSON/ASN.1/tar/etc.), compression, cryptography, parsers/grammars/DSLs
(regex/PEG/Datalog/Prolog/GraphQL), the typechecker and language tooling,
web/UI frameworks, reactive/state libraries, async/concurrency primitives,
general data structures (tries/heaps/skip lists/CRDTs), storage/DB layers,
OS/FFI/platform capability system, or the FP/optics toolkit. This is
expected and not itself a finding — unshape doesn't claim this scope.

## 4. Architectural patterns worth porting

**Capability-tiered backend selection via a trait + registry, not an
if-chain.** `unshape-backend`'s `ComputeBackend` trait +
`BackendRegistry::with_cpu()` + `ExecutionPolicy` (`Auto`/pin-to-backend)
+ `Scheduler` cleanly separates "what backends exist," "what a workload
needs" (`WorkloadHint`, `Cost`), and "how to pick" — new backends register
without touching the scheduler. crescent's tier system (system > FFI > pure
Lua, `docs/conventions.md`) is conceptually the same idea but implemented
per-library via ad hoc `pcall`-and-fall-through at load time. A shared
`lib/backend/`-style registry (trait/interface + registry + policy) could
replace the copy-pasted tier-selection boilerplate across `lib/crypto/`,
`lib/compress/`, `lib/regex/`, `lib/stb/`, etc. with one reusable mechanism,
and would make the "never silently use a slow tier" rule mechanically
checkable (the registry can log/assert which backend was chosen) instead of
convention-enforced per file.

**Serializable ops as a typed, registry-validated pipeline —
`unshape-op`'s `#[derive(Op)]` / `DynOp` / `OpRegistry` / `Pipeline`.**
Every domain crate (automata, fluid, physics, rd, lsystem, ...) exposes a
`register_ops(&mut OpRegistry)` that makes its operations loadable from a
serialized pipeline with type validation *at load time*, not at execution
time — `Pipeline::validate()` checks the input/output type chain matches
before running anything. crescent has the pieces (`lib/pipeline/`,
`lib/pipeline_dsl/`, `lib/taskgraph/`, `lib/task_runner/`) but nothing that
combines "derive-macro-free registration + load-time type validation +
serialize/replay" the way `unshape-op` + `unshape-serde` do together. This
pattern is a strong match for crescent's `lib/pkg/` design work (a
package/pipeline manifest that needs to validate before executing) and for
`lib/platform/` app pipelines (validating a pack's declared op chain before
running it in the sandbox).

**Unifying trait over dimensionality — `unshape-transform::SpatialTransform`
and `unshape-curve::Curve`.** Rather than writing parallel 2D/3D versions of
every algorithm, unshape defines one trait (`SpatialTransform` with
associated `Vector`/`Rotation`/`Matrix` types) implemented once each by
`Transform2D` and `Transform3D`, letting generic code (rigging, motion) work
unmodified across dimensions. crescent's geometry libs
(`lib/geom/`, `lib/geometry_3d/`, `lib/matrix/`) are separate 2D/3D
implementations with no shared interface — any future geometry work
(the mesh/rig gap noted in §2, if crescent ever builds it) should reach for
this pattern instead of duplicating logic per dimension the way the current
2D-only libs already imply it would.

**Dual history strategies behind one decision table —
`unshape-history`'s explicit snapshot-vs-event-sourcing tradeoff table in
the module doc comment**, with both implemented as swappable `HistoryError`
-returning APIs rather than one "chosen" approach. crescent's
`lib/event_sourcing/` only does the event-sourcing side; there's no
snapshot-based undo/redo library, and no doc anywhere that states the
tradeoff as directly as unshape's doc comment does. Worth stealing verbatim
for any crescent library facing the same choice (e.g. `lib/platform/`
app-state undo, or editor-style tools).

**Doc comments that carry a runnable example plus a rationale paragraph.**
Nearly every unshape crate's `lib.rs` opens with a `//!` block containing a
working code example *and* a sentence of "why this crate, why this
boundary" (e.g. `unshape-geometry`'s "for geometry attribute traits, see
`unshape-geometry`... this crate stays generic"). crescent's convention docs
ask for accurate naming but the inventory entries are written by an outside
surveyor after the fact, not carried in-source; adopting unshape's
practice of a rationale-bearing module doc comment per library would make
`docs/inventory.md` maintenance cheaper (grep the crate, don't reconstruct
intent from code).
