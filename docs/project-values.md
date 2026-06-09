# Project Values

Crescent should not be reduced to one thesis.

Several values are intended to coexist in the same shipped distribution. A
decision can serve one value and strain another, so design notes should say
which value a decision serves instead of implying a universal "correct" answer.

## Coequal Values

### Computer Control Surface

Crescent is an operating environment: a programmable control surface for the
computer.

This is not limited to package management, developer tooling, or a Lua library
collection. Those are entry points and implementation material. The broader
goal is that the user can operate, inspect, automate, and reshape their computer
through one coherent local surface.

### Capability App Platform

`lib/platform` is a first-class value axis.

The platform goal is capability-based app execution: apps receive explicit
authority, not ambient access. Apps may be distributed as whole codebase
artifacts, including archives or image-carried bundles, and then run under the
same capability model.

Bundled first-party apps are not a privileged runtime class. They are developed
in-tree and included in the default distribution, but they should be subject to
the same app/capability semantics as third-party apps except where a distribution
or signing policy explicitly says otherwise.

### Knowledge

Knowledge is itself a project value.

This is not merely documentation for the codebase, a teaching method, or a
separate medium. Crescent should ship useful knowledge as part of the same
artifact that ships tools and apps. A user may install Crescent for one concrete
app and still receive the rest of the first-party app/content corpus because the
distribution is one dense object.

The practical consequence is that examples, explanations, rejected designs,
proof traces, visualizations, and "why not this?" material can be product
material when they help users understand or modify the computer they received.
They should not be discarded automatically as scaffolding.

## Distribution Thesis

The default distribution is allowed to be broad.

Installing one app can incidentally install the rest of the first-party app
suite, the platform runtime, the libraries, and the knowledge corpus. This is
not a layering violation by itself. It is part of the value proposition as long
as bundled apps remain ordinary apps and the artifact stays small enough to be
reasonable.

Splitting into many repositories or packages is not inherently more correct.
Separation should be justified by real ownership, release, authority, or size
boundaries, not by an assumed rule that values must be packaged separately.

## Status Language

Design claims should avoid implying universal correctness.

Use status words deliberately:

- `Rejected`: a counterexample or value conflict is known.
- `Viable`: not ruled out; not adopted.
- `Adopted`: currently used by the project.
- `Canonical`: the current coordination story or representation.
- `Load-bearing`: other work depends on it.
- `Provisional`: useful now, expected to be revised.
- `Open`: no project decision yet.

`Canonical` does not mean universally correct. `Adopted` does not mean final.
`Not rejected` does not mean right.

Prefer phrasing like:

```text
We are proceeding under X because it serves Y under assumptions Z.
It should be revisited if W happens.
```

## Consequences For Typechecker Work

Typechecker, static-checker, and program-proof work are infrastructure and
knowledge material. They are not automatically a coequal value axis by
themselves.

They matter when they serve one or more project values:

- making apps and capability boundaries inspectable or enforceable;
- making first-party and third-party code safer to modify;
- producing useful knowledge artifacts such as proof traces and executable
  explanations;
- improving the computer control surface through better diagnostics,
  navigation, or automation.

A proof/evidence framework may still be the right substrate for some of this
work, but that must remain a project-relative claim, not a universal story about
what Crescent "really is."
