# Prior Art Survey: Modular, Sound, Coverage-Gradual Typecheckers

**Research date:** 2026-06-12  
**Researcher:** Claude (deep-research harness)  
**Question:** Is the 4-property combination — (A) gradual-in-coverage + fully sound, (B) modular/pluggable with independently-usable analyses, (C) for real dynamically-typed languages + unannotated code, (D) de-special-cased single value-set lattice — occupied by existing work, or a partial gap?

---

## The Four Target Properties (Precise Definitions)

**Property A — Gradual in semantic COVERAGE, fully SOUND in type-safety.**
The set of language constructs the checker understands grows incrementally; over its covered domain it is fully sound (no false negatives). Unhandled constructs receive a *sound* `unknown` (⊤, top of the type lattice — callers must narrow before use), NOT an *unsound* `any`/`dyn` (which is compatible with everything without narrowing, permitting silent errors). This is the **opposite** of Siek–Taha gradual typing, which is gradual in *safety*: `?`/`dyn` is unsound — soundness is traded at the dynamic boundary via casts/blame. The Siek–Taha `?` is the *unknown precision* type, not a sound top type; it is consistency-compatible with every type (including wrong ones), making it inherently unsound.

**Property B — Highly modular / pluggable.**
The type system decomposes into independently-meaningful analyses, each of which is sound and useful alone. You can stop adding modules at any point.

**Property C — For a real (dynamically-typed) language.**
Checking largely-unannotated existing code; not a clean-slate typed calculus or a statically-typed host language.

**Property D — De-special-cased.**
Most "features" (nil, unions, records, literals, recursion, refinements) are enrichments of ONE value-set/subtyping lattice, NOT separate passes. Only genuinely-orthogonal judgements (effects, linearity, taint, termination) get their own composable layer.

---

## The Contrast: Siek–Taha Gradual Typing (Verified)

**Source:** Siek & Taha, "Gradual Typing for Functional Languages," Scheme and Functional Programming Workshop, 2006.  
**Scholar link:** https://scholar.google.com/scholar?q=Siek%2C+J.G.%2C+Taha%2C+W.%3A+Gradual+typing+for+functional+languages

The Siek–Taha `?` (dynamic type) is **gradual in safety, not coverage**. Their key mechanism is *type consistency* — a relation that is reflexive and symmetric but NOT transitive, allowing `?` to be consistent with every type. This intentionally permits unsound static checking; soundness is recovered at runtime via casts/blame. As confirmed by the Wikipedia article on gradual typing (https://handwiki.org/wiki/Gradual_typing): "a special type named dynamic is used to represent statically-unknown types... to achieve soundness, runtime checks are required." The `?` type is not a sound top type — it is an *escape hatch from the type lattice*. Systems using `?` as a top-compatible type (most modern gradual type systems) are **not** gradual in coverage; they are gradual in safety.

The AGT (Abstracting Gradual Typing) framework by Garcia, Clark, and Tanter (POPL 2016) systematizes Siek–Taha by formalizing gradual types as sets of static types via a Galois connection, with `?` as the *least precise* type (top of a precision lattice, not top of the type lattice). AGT starts with a sound static type system and adds gradualness — but the resulting `?` remains consistency-compatible with all types, hence unsound. The "gradual guarantees" (static and dynamic) are properties of the precision ordering, not soundness in the type-safety sense.  
**Source:** https://dl.acm.org/doi/10.1145/2914770.2837670

---

## Prior Art Map

### 1. Bracha — "Pluggable Type Systems" (2004)

**Sources:**
- Position paper: https://bracha.org/pluggableTypesPosition.pdf (verified reachable)
- Slides: https://bracha.org/pluggable-types.pdf (certificate expired at time of survey)
- ResearchGate copy: https://www.researchgate.net/publication/213885984_Pluggable_Type_Systems

**What it actually does:** Bracha's 2004 OOPSLA workshop position paper argues that type systems should be optional plugins to the language, decoupled from its syntax and semantics. A pluggable type system "has no effect on language semantics" and "neither requires syntactic annotations nor affects runtime semantics." This is a *vision document*, not a formal system.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | Partial | Bracha explicitly argues for *optionality*, not soundness. The paper does not claim checkers should be sound; the goal is expressivity and freedom of choice. No treatment of `unknown` vs `any`. |
| B (modular/pluggable) | **Yes** | This is the central proposal: type systems as independent, interchangeable plugins. |
| C (dynamic language, unannotated) | **Yes** | Bracha's target is dynamically-typed languages like Newspeak and Smalltalk; programs should run unchanged regardless of type plugin. |
| D (single lattice) | No mention | Not addressed; position paper only. |

**Gap:** Does not establish soundness requirements on plugins; does not define `unknown` vs `any`. B+C present, A and D absent.

---

### 2. Checker Framework — Ernst et al. (2008, ongoing)

**Sources:**
- Original paper: https://homes.cs.washington.edu/~mernst/pubs/pluggable-checkers-issta2008.pdf
- Manual: https://checkerframework.org/manual/
- ICSE 2011: https://homes.cs.washington.edu/~mernst/pubs/pluggable-checkers-icse2011.pdf

**What it actually does:** The Checker Framework implements Bracha's pluggable-types vision for Java. Type checker authors define qualifier hierarchies and enforcement rules; each checker (Nullness, Tainting, Index, Lock, etc.) can be used independently or combined. It integrates with javac.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | **No** | The manual explicitly states: "The Checker Framework is, by default, unsound in a few places where a conservative analysis would issue too many false positive warnings." Unannotated code gets default annotations (e.g., `@NonNull` for Nullness) that are *assumed correct without verification*: "the annotations on the un-checked code are trusted; there is no verification that the implementation of the native method satisfies the annotations." This is not sound-unknown — it is a trusted default that can silently miss errors. |
| B (modular/pluggable) | **Yes** | 28+ independently-runnable checkers; the framework is explicitly designed for independent composition. |
| C (dynamic language) | **No** | Java only. Java is a statically-typed language with a bytecode VM. Not applicable to largely-unannotated dynamically-typed language code. |
| D (single lattice) | Partial | Each checker defines its own qualifier lattice; the base type lattice is Java's static type system. Multiple qualifier hierarchies can coexist but are separate from each other. Not a single unified value-set lattice. |

**Gap:** B present strongly. A explicitly absent (unsound by default). C absent (wrong language class). D partial (parallel lattices, not unified).

---

### 3. "Type Systems as Macros" — Chang, Knauth, Greenman (POPL 2017) + Turnstile+/POPL 2020

**Sources:**
- POPL 2017 page: https://popl17.sigplan.org/details/POPL-2017-papers/26/Type-Systems-as-Macros
- Paper PDF: http://stchang.github.io/pubs/ckg-popl2017.pdf
- ACM: https://dl.acm.org/doi/10.1145/3009837.3009886
- Turnstile+ (POPL 2020): https://dl.acm.org/doi/10.1145/3371071

**What it actually does:** Turnstile (2017) and Turnstile+ (2020) implement typed embedded DSLs in Racket as macros. Type-checking rules are written as macro transformation rules; the macro system simultaneously type-checks and elaborates. Rules are composable and can be mixed to create new type systems. Turnstile+ extends this to dependent types.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | Partial | The produced type systems are designed to be sound (they are full static type systems). However, the *target* is clean-slate embedded languages, not unannotated existing code. There is no mechanism for gracefully handling unanalyzed positions with sound `unknown`. |
| B (modular/pluggable) | **Yes** | The central claim: "reusing a macro system yields modular implementations whose rules may be mixed and matched to create other systems." Individual type rules are compositional. |
| C (dynamic language, unannotated) | **No** | The target is typed embedded DSLs built *on top of* untyped Racket. The DSLs themselves require type annotations. This is not checking unannotated existing code in a dynamic language — it is creating new typed languages. |
| D (single lattice) | Partial | Within a single composed type system, yes — types form a lattice. But the framework is neutral on what lattice to use; each embedded DSL makes its own choice. Not about enrichments of one value-set lattice. |

**Gap:** B present. C absent (creates new typed languages rather than checking existing dynamic-language code). A partial (sound within a DSL, but no graceful unknown for uncovered constructs). D not addressed.

---

### 4. Qualified Types — Mark P. Jones (1992/1994)

**Sources:**
- ESOP 1992: http://web.cecs.pdx.edu/~mpj/pubs/esop92.html
- Book: http://web.cecs.pdx.edu/~mpj/pubs/thesis.html
- ACM: https://dl.acm.org/doi/10.1145/3290325 (related rows extension)

**What it actually does:** Jones' qualified types provide a uniform framework for type classes, subtyping, and extensible records by adding *predicates* to types: `P => T`. By changing the predicate system, you get different "extensions" of the Hindley–Milner base. This is a formal mechanism for composing type system features.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | Partial | Qualified types are sound by construction (principal types, coherence). But coverage-gradualism — incremental understanding of constructs with sound `unknown` fallback — is not a design goal. The system is complete (all terms typeable or rejected) not partial. |
| B (modular/pluggable) | **Yes** | The predicate system is the extension point; different predicate interpretations give different "type qualifiers," composable by combining predicates. |
| C (dynamic language, unannotated) | **No** | Qualified types target ML-family statically typed languages with full type inference. Not designed for dynamically-typed unannotated code. |
| D (single lattice) | **Yes** | The base is one Hindley–Milner type structure; predicates are enrichments. This directly corresponds to the de-special-cased ideal. |

**Gap:** B and D present. C absent (static language). A absent (not coverage-gradual — assumes total coverage and full type inference).

---

### 5. Cousot — Abstract Interpretation and "Types as Abstract Interpretations" (1977/1997)

**Sources:**
- Original AI paper: https://dl.acm.org/doi/10.1145/512950.512973 (POPL 1977)
- Types as Abstract Interpretations (POPL 1997): https://www.di.ens.fr/~cousot/COUSOTpapers/POPL97.shtml
- Reduced product: https://www.di.ens.fr/~cousot/COUSOTpapers/publications.www/CousotCousotMauborgne-FoSSaCS11-LNCS6604-proofs.pdf
- OPAL modular analysis: https://arxiv.org/abs/2010.04476

**What it actually does:** Abstract interpretation is a theory of sound over-approximation of program semantics. The reduced product operation combines multiple abstract domains, with each component domain contributing sound observations and the combination tightening via information exchange. Cousot's 1997 paper shows that type systems *are* abstract interpretations — abstract collecting semantics over the untyped lambda calculus — deriving a hierarchy of type systems via Galois connections. This is a *theoretical unification*, not a user-facing tool. The top element (⊤) in any abstract domain corresponds to the completely unknown value, and analyses that reach ⊤ for a term are sound (they have learned nothing). The OPAL framework (2020) uses blackboard-style modular analyses that are exchangeable and pluggably extensible, and is sound by the abstract interpretation methodology.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | **Yes (theoretically)** | Abstract interpretation is sound by construction: top element = sound unknown, bottom = unreachable. Reduced products combine sound analyses. However, this is a *research methodology*, not a user-facing type system. User-facing tools built on AI (Astrée, etc.) are for C/imperative code, not general dynamically-typed languages. |
| B (modular/pluggable) | **Yes (theoretically)** | Reduced products are exactly modular combination of independent sound analyses. OPAL formalizes this as exchangeable, pluggable analysis components. |
| C (dynamic language, unannotated) | Partial | Abstract interpretation can analyze dynamically-typed code (e.g., Python analyzers like Pysa). But the *user-facing* systems are not designed as modular type systems for dynamic-language programmers; they are static analyzers. The "type system" packaging for programmers is absent. |
| D (single lattice) | **Yes** | Abstract domains are value-set lattices; analyses are enrichments of one semantic domain. This is exactly the de-special-cased ideal, at the theory level. |

**Gap:** The abstract interpretation framework has A, B, D theoretically. C is partially present (can analyze dynamic code) but the *user-facing type system packaging* for dynamic-language programmers, with incrementally-growing coverage, is absent. Cousot 1997 is the closest *theoretical* ancestor of the target architecture but has never been packaged as a user-facing modular-sound-coverage-gradual type system.

---

### 6. Dialyzer — Success Typings (Lindahl & Sagonas, PPDP 2006)

**Sources:**
- Paper: https://www2.it.uu.se/itwiki.php?page=research/group/hipe/dialyzer&action=browse
- "A Falsification View of Success Typing": https://arxiv.org/pdf/1502.01278
- Springer chapter: https://link.springer.com/chapter/10.1007/978-3-642-12251-4_2

**What it actually does:** Dialyzer infers *success typings* for Erlang: type signatures that over-approximate the set of input-output types for which a function can succeed (not crash). Success typings guarantee no false positives: if Dialyzer reports an error, it is a definite error. However, Dialyzer is explicitly **not** sound — it has false negatives. Success typings are the *opposite* trade from soundness: it trades completeness (may miss real errors) for precision (no false alarms). This is for a real dynamically-typed language (Erlang) with unannotated code.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | **No — explicitly opposite** | Success typings are no-false-positive but have false negatives (unsound). This is the opposite of the target. The target wants no false negatives over the covered domain; Dialyzer wants no false positives even at the cost of missed errors. |
| B (modular/pluggable) | No | Dialyzer is a monolithic whole-program analysis. Not structured as independently-meaningful modular analyses. |
| C (dynamic language, unannotated) | **Yes** | Erlang is dynamically typed; Dialyzer works without annotations (accepts optional type specs). |
| D (single lattice) | Partial | Success typings operate on a type domain for Erlang values, unified around the term lattice. But not framed in terms of enrichments of a single lattice. |

**Gap:** C present. A is the opposite trade (no false positives vs sound no false negatives). B absent. Dialyzer is an explicit contrast, not a match.

---

### 7. Liquid Types / Refinement Types as Optional Layer (Rondon, Kawaguchi, Jhala, PLDI 2008)

**Sources:**
- Paper: https://goto.ucsd.edu/~rjhala/liquid/liquid_types.pdf
- Tech report: https://goto.ucsd.edu/~rjhala/liquid/liquid_types_techrep.pdf
- Overview: https://goto.ucsd.edu/~ucsdpl-blog/liquidtypes/2015/09/19/liquid-types/

**What it actually does:** Liquid types layer refinement predicates (drawn from a decidable predicate language) on top of Hindley–Milner types using predicate abstraction and SMT solving. Inference is fully automatic. The target is ML-family languages (originally OCaml/C). The system is sound: if it does not report errors, the refinements hold. Unannotated code is handled by inference. A fixed set of predicates is chosen; only properties expressible in that predicate language are checked.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | Partial | Sound over its covered domain (liquid type predicates). Properties outside the predicate language are simply not checked — this is coverage-limited in the right spirit. However, the "uncovered" positions are handled by falling back to the base ML type (not a sound `unknown`/⊤ at the term level). No explicit `unknown` propagation. |
| B (modular/pluggable) | Partial | The refinement layer is separable from the base HM type system. But the choice of predicates is global and fixed; you can't add/remove refinement analyses independently. |
| C (dynamic language, unannotated) | **No** | Target is statically-typed ML/C. Not for dynamically-typed unannotated code. |
| D (single lattice) | **Yes** | Refinements enrich one base type lattice (HM types + predicates). This is the de-special-cased approach — one lattice enriched with predicates. |

**Gap:** D present. A partially present (sound over covered domain, but not explicit sound-unknown for uncovered). C absent (static language). B partial.

---

### 8. Graded Modal / Coeffect Type Systems (Orchard, Petricek, Gaboardi, et al., 2014–2024)

**Sources:**
- Granule (ICFP 2019): https://dl.acm.org/doi/pdf/10.1145/3341714
- Graded Modal Dependent Type Theory: https://arxiv.org/pdf/2010.13163
- Information-flow coeffects: https://granule-project.github.io/papers/security-coeffects-mycroftfest.pdf

**What it actually does:** Graded modal type systems use a semiring-indexed `!`-modality to track *how* resources (values) are used: linearity, sensitivity, information-flow security labels, and similar. The grading semiring is a pluggable parameter — changing it gives different properties (linearity, security, etc.). This provides a composable mechanism for adding orthogonal judgment axes to a type system.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | **No** | Graded systems are full type systems requiring complete annotation (or inference) of grades on all terms. There is no mechanism for incrementally-covered checking with sound `unknown` fallback. |
| B (modular/pluggable) | **Yes (for orthogonal axes)** | The semiring is the extension point; different semirings give different analyses. This is a clean mechanism for the "only genuinely-orthogonal judgements get their own composable layer" part of Property D. |
| C (dynamic language, unannotated) | **No** | Granule and related systems target new typed languages or typed functional languages. Not for unannotated dynamic code. |
| D (single lattice) | **Yes** | The base type lattice is unified; grades are annotations on the lattice structure. The graded comonad mechanism is the enrichment mechanism. |

**Gap:** B and D partial/yes (for the orthogonal-axes part). A and C absent. Useful as a model for how to add effects/linearity/taint *to* the target architecture, but does not itself occupy the target.

---

### 9. Flix (Madsen et al., PLDI 2016+)

**Sources:**
- PLDI 2016: https://dl.acm.org/doi/10.1145/2908080.2908096
- Semantic Scholar: https://www.semanticscholar.org/paper/From-Datalog-to-flix:-a-declarative-language-for-on-Madsen-Yee/50e8b66fad4dd05e1e5e776ffc08b2d4c80b5a3f
- OOPSLA 2025 (Flix as language-integrated Datalog): https://dl.acm.org/doi/10.1145/3763126

**What it actually does:** Flix is a declarative language for writing static program analyses as fixpoint computations over user-defined lattices. Analyses compose naturally when their lattices are compatible. It is a *framework for writing analyses*, not a type system for end-users.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | Partial | Analyses written in Flix are sound by construction (monotone functions over lattices reach fixed points that over-approximate). Top of a lattice = sound unknown. But Flix is a research/analysis-author tool, not a user-facing type system. |
| B (modular/pluggable) | **Yes** | Analyses compose via lattice product. Independently meaningful analyses can be combined or used alone. |
| C (dynamic language, unannotated) | Not directly | Flix analyses can target any language (Java bytecode, etc.), but Flix itself is a statically-typed language. The framework doesn't specifically target dynamic-language unannotated code as a user-facing type system. |
| D (single lattice) | **Yes** | User-defined lattices are the core; analyses are lattice enrichments. |

**Gap:** B, D present. A theoretically present but not packaged as user-facing. C absent as user-facing product.

---

### 10. Doop / CodeQL — Declarative/Composable Analysis Substrates

**Sources:**
- Doop: https://dl.acm.org/doi/10.1145/2908080.2908096 (context — Flix paper cites Doop)
- CodeQL (GitHub): https://codeql.github.com

**What it actually does:** Doop is a Datalog-based points-to analysis framework for Java. CodeQL is a query language for program analysis across multiple languages. Both allow composing analyses as rules/queries. Neither is a user-facing type system; both are analysis infrastructure.

**Property mapping:** B and D partially present at the substrate level. A absent as user-facing. C absent (not presented as a type system for dynamic-language programmers).

---

### 11. Elixir Gradual Set-Theoretic Type System (Castagna, Duboc, Valim, 2022–2026)

**Sources:**
- Design Principles paper (Programming 2024): https://arxiv.org/abs/2306.06391
- Guard Analysis paper (arXiv 2024): https://arxiv.org/abs/2408.14345
- Elixir blog — set-theoretic types (2022): https://elixir-lang.org/blog/2022/10/05/my-future-with-elixir-set-theoretic-types/
- Strong arrows blog (2023): https://elixir-lang.org/blog/2023/09/20/strong-arrows-gradual-typing/
- Elixir v1.18 release (2024): https://elixir-lang.org/blog/2024/12/19/elixir-v1-18-0-released/
- Elixir v1.21-dev docs: https://hexdocs.pm/elixir/main/gradual-set-theoretic-types.html

**What it actually does:** Elixir is a dynamically-typed functional language on the BEAM VM. The ongoing effort (led by Castagna/Duboc, now implemented by Valim in the compiler) adds a set-theoretic type system based on semantic subtyping. Key properties verified from docs and papers:

1. **`dynamic()` type semantics (verified from hexdocs):** "`dynamic()` works as a range of types... by intersecting a type with `dynamic()`, we make the type gradual and therefore only a subset of the type needs to be valid." Unannotated functions are typed as `(dynamic() -> dynamic())`, then refined by patterns/guards. This is *not* a sound `unknown`/⊤ that forces narrowing before use — it is *intersection-based*: `dynamic() and T` means "we expect T, but are gradual about it." The docs note: "the type system will not emit a warning" when calling `Integer.to_string(var)` if `var :: dynamic() and (atom() or integer())` because *some* branch is valid.

2. **Soundness (verified):** "the inferred and assigned by the type system align with the behaviour of the program." The Guard Analysis paper states: "Type soundness is ensured by leveraging runtime checks — both implicit, from the Erlang VM, and explicit, via developer-written guards." This is **safe erasure** gradual typing — types are erased before execution, and soundness relies on pre-existing VM checks and developer guards, NOT on compiler-inserted casts. This is a novel and important distinction.

3. **Coverage (verified from docs):** "At this moment, Elixir implements type inference of all language constructs." The system aims for full coverage of Elixir, rolling out incrementally (patterns/guards → typed structs → function signatures). Currently in v1.18–1.21: inference from patterns, guards, and return types. User-provided signatures are planned. This is incremental *deployment*, not incremental *coverage* — the goal is full language coverage.

4. **`dynamic()` vs sound `unknown` (key distinction):** The `dynamic()` type is *not* a sound `unknown`/⊤. It is more like a bounded `any`: it is produced by unannotated code and propagates through calls, but it does not *block* operations without narrowing. It is compatible with operations that work on *some* branch. This is closer to Siek–Taha's `?` than to a sound `unknown` — it trades some soundness for reduction of false positives. From search results: "The type `term` is the top type in the subtyping relation. The type `any` is used to denote the unknown type and represents dynamically typed fragments of code." — confirming `dynamic()`/`any` is the compatibility-escape type, not a blocked-until-narrowed top.

**Property mapping:**
| Property | Match? | Detail |
|---|---|---|
| A (sound coverage-gradual) | **Partial/No** | Sound over annotated code (via VM checks). But `dynamic()` is not a sound `unknown` — it does not block uses without narrowing. It is a bounded compatibility type, which preserves some unsoundness for unannotated positions. Gradual in coverage (constructs covered incrementally) in deployment, but `dynamic()` semantics are closer to Siek–Taha `?` than to sound ⊤. |
| B (modular/pluggable) | **No** | The type system is a monolithic unified system, not decomposed into independent analyses. There is no pluggable-analysis API. |
| C (dynamic language, unannotated) | **Yes** | Exactly the target setting: Elixir is dynamic, existing unannotated code is checked by inference. This is the closest existing work on C. |
| D (single lattice) | **Yes** | Set-theoretic types *are* a single lattice under set operations (union, intersection, negation, subtyping). Features like nil, atoms, integers, tuples, and guards are all part of one type lattice, not separate passes. This is the de-special-cased ideal. |

**Gap:** C and D present strongly. B absent. A partial: sound in principle (leverages VM checks) but `dynamic()` is not a blocked-until-narrowed sound ⊤. Closest existing work to the target, missing B and with a different flavor of A.

---

### 12. Typing Systems for Python — Pyright, mypy, pytype, Pysa

**Sources:**
- Pytype: https://github.com/rezeik/pytype
- Pyright Unknown docs: https://fossies.org/linux/pyright/docs/type-inference.md
- Gradual Soundness paper (Static Python, arXiv 2022): https://arxiv.org/pdf/2206.13831
- ECOOP 2023 paper on Python hints: https://drops.dagstuhl.de/storage/00lipics/lipics-vol263-ecoop2023/LIPIcs.ECOOP.2023.44/LIPIcs.ECOOP.2023.44.pdf

**What they actually do:**
- **mypy**: Gradual in coverage — unannotated functions are skipped by default (they get implicit `Any`). `Any` is unsound. Not modular.
- **Pyright**: Uses `Unknown` (described as "a special form of Any"). Pyright has a `--verifytypes` coverage score. But `Unknown` is treated as implicit `Any`, not as a sound ⊤. Not modular/pluggable.
- **Pytype**: Infers types for unannotated Python. Attempts soundness but is not formally sound.
- **Pysa**: Taint analysis, not a type system.

None of these satisfy A (sound coverage-gradual with blocked-until-narrowed ⊤) or B (modular/pluggable independent analyses).

---

### 13. "Sound Gradual Verification with Symbolic Execution" (POPL 2024)

**Source:** https://arxiv.org/abs/2311.07559

**What it does:** Proves soundness of gradual *verification* (pre/postcondition specs), not gradual *type checking*. The "gradual" is about partially-specified verification contracts, not type coverage. Supports incremental verification coverage. But this is for verification/proofs (Viper tool), not a type system for dynamic language code.

**Property mapping:** A partially (sound over verified portions, unverified portions deferred to runtime). C: No (targets static-ish verification languages). B and D: not addressed.

---

## Adversarial Verification of Key Claims

**Claim: "Siek–Taha `?` is unsound."**  
Verified: The Wikipedia gradual typing article and the AGT paper (POPL 2016) confirm that the Siek–Taha `?` requires runtime casts for soundness; the static type system with `?` is not sound without them. The `?` is consistent-with-everything statically, which is by design an unsound static judgment.

**Claim: "Checker Framework is sound by default."**  
Falsified: The Checker Framework manual explicitly states it "is, by default, unsound in a few places." Unannotated library code is trusted, not verified.

**Claim: "Elixir's `dynamic()` is a sound unknown/⊤."**  
Partially falsified: From the docs, `dynamic() and T` allows operations valid for *some* branch — it does not block all operations until narrowing. The hexdocs confirm `dynamic()` is a "range of types" intersected with concrete types. The system docs state `term` is top and `any`/`dynamic()` is the unknown-compatible type. This is not the same as a sound ⊤ that blocks all use. The safe-erasure approach (Castagna/Duboc 2024) claims soundness by relying on VM checks — but only for what the VM checks, not all operations.

**Claim: "Type Systems as Macros targets dynamically-typed language checking."**  
Falsified: The paper targets *building typed DSLs* inside Racket. The DSLs are typed from the start; this is not checking existing unannotated code.

---

## Verdict: Is the 4-Property Combination Occupied?

**No clear prior work combines all four properties. The combination is a gap in the existing literature, with the closest work missing at least one property.**

The exact architecture — (A) sound `unknown`/⊤ for uncovered positions (callers must narrow), fully sound over covered domain; (B) independently-usable modular analyses that compose; (C) for real dynamically-typed unannotated code; (D) single value-set lattice with features as enrichments — does not appear to be occupied.

### Closest Matches

**1. Elixir set-theoretic type system (Castagna, Duboc, Valim, 2022–2026)**  
- Has: C (real dynamic language, unannotated code), D (single set-theoretic lattice), and sound-in-principle via VM checks  
- Missing: B (not modular/pluggable — monolithic system), A precisely (dynamic() is not a blocked-until-narrowed ⊤; it is a compatibility type closer to bounded `any`)  
- Source: https://arxiv.org/abs/2306.06391, https://arxiv.org/abs/2408.14345

**2. Cousot "Types as Abstract Interpretations" + AI reduced products (1997, 2011)**  
- Has: A theoretically (⊤ = sound unknown, reduced product = modular combination), B theoretically (independent sound domains), D (analyses as enrichments of one semantic domain)  
- Missing: C as a user-facing product (not packaged as a type system for dynamic-language programmers; tools built on AI target C/imperative code, not user-facing modular type systems)  
- Source: https://www.di.ens.fr/~cousot/COUSOTpapers/POPL97.shtml, https://cs.nyu.edu/~pcousot/COUSOTpapers/FoSSaCS-11.shtml

**3. Checker Framework (Ernst et al., 2008–ongoing)**  
- Has: B (strong — 28+ independent pluggable checkers)  
- Missing: A (explicitly unsound by default; unannotated code is trusted, not assigned sound ⊤), C (Java only — statically-typed language), D (parallel qualifier lattices, not unified)  
- Source: https://checkerframework.org/manual/

### Honorable Mentions

- **Qualified types (Jones 1992):** Has B and D (enrichments of one HM lattice); missing C (static language) and A (not coverage-gradual).
- **Flix (Madsen 2016):** Has B and D at the substrate level; missing C (user-facing) and A (not packaged as user-facing type system).
- **Liquid types (Rondon/Jhala 2008):** Has D (single enriched lattice) and partial A (sound over covered domain); missing C (static language) and B (global predicate choice, not modular).
- **Graded modal types (Orchard/Petricek/Gaboardi):** Has B and partial D (for orthogonal axes); missing A and C.

### Most Useful Recent Reference

**"Guard Analysis and Safe Erasure Gradual Typing: A Type System for Elixir"**  
Castagna & Duboc, arXiv 2408.14345, 2024.  
https://arxiv.org/abs/2408.14345  
Reason: Most recent work that correctly identifies the problem setting (real dynamic language, sound, unannotated code, single semantic-subtyping lattice) and makes progress on it; the "safe erasure" approach (no compiler-inserted casts, soundness via VM checks) is novel and directly relevant. Its failure to achieve B (modularity) and its use of `dynamic()` as a bounded-any rather than sound ⊤ mark the gap this survey is designed to identify.

---

## Summary Table

| Work | A: Sound coverage-gradual | B: Modular/pluggable | C: Dynamic unannotated | D: Single lattice |
|---|---|---|---|---|
| Siek–Taha gradual typing | **NO** (safety-gradual, opposite) | No | Partial | No |
| Bracha pluggable types | No (not claimed) | **YES** | **YES** | Not addressed |
| Checker Framework | **NO** (unsound default) | **YES** | No (Java) | Partial |
| Type Systems as Macros | Partial (sound within DSL) | **YES** | **NO** (creates DSLs) | Partial |
| Qualified types | No (total, not coverage-gradual) | **YES** | No (static) | **YES** |
| Cousot AI + reduced product | **YES** (theoretical) | **YES** (theoretical) | Partial (not user-facing) | **YES** (theoretical) |
| Dialyzer success typings | **NO** (opposite: no-FP, has-FN) | No | **YES** | Partial |
| Liquid/refinement types | Partial | Partial | No (static) | **YES** |
| Graded modal types | No | **YES** (for orthogonal axes) | No | Partial |
| Flix | Partial (theoretical) | **YES** | No (not user-facing) | **YES** |
| Elixir set-theoretic | Partial (VM-sound, dynamic()≠⊤) | **NO** (monolithic) | **YES** | **YES** |
| Python tools (mypy/Pyright) | No (Any, not sound ⊤) | No | Partial | No |

**No work occupies all four cells simultaneously.**

---

## Sources (All Verified)

- Bracha, "Pluggable Type Systems," OOPSLA 2004 workshop: https://bracha.org/pluggableTypesPosition.pdf
- Papi, Ali, Glasser, Lam, Ernst, "Practical Pluggable Types for Java," ISSTA 2008: https://homes.cs.washington.edu/~mernst/pubs/pluggable-checkers-issta2008.pdf
- Checker Framework Manual: https://checkerframework.org/manual/
- Chang, Knauth, Greenman, "Type Systems as Macros," POPL 2017: https://dl.acm.org/doi/10.1145/3009837.3009886
- Chang et al., "Dependent Type Systems as Macros," POPL 2020: https://dl.acm.org/doi/10.1145/3371071
- Jones, "A Theory of Qualified Types," ESOP 1992: http://web.cecs.pdx.edu/~mpj/pubs/esop92.html
- Siek & Taha, "Gradual Typing for Functional Languages," SFP 2006: https://scholar.google.com/scholar?q=Siek%2C+J.G.%2C+Taha%2C+W.%3A+Gradual+typing+for+functional+languages
- Garcia, Clark, Tanter, "Abstracting Gradual Typing," POPL 2016: https://dl.acm.org/doi/10.1145/2914770.2837670
- Cousot, "Types as Abstract Interpretations," POPL 1997: https://www.di.ens.fr/~cousot/COUSOTpapers/POPL97.shtml
- Cousot, Cousot, Mauborgne, "The Reduced Product of Abstract Domains," FoSSaCS 2011: https://cs.nyu.edu/~pcousot/COUSOTpapers/FoSSaCS-11.shtml
- Lindahl & Sagonas, "Practical Type Inference Based on Success Typings," PPDP 2006: https://www2.it.uu.se/itwiki.php?page=research/group/hipe/dialyzer&action=browse
- "A Falsification View of Success Typing": https://arxiv.org/pdf/1502.01278
- Rondon, Kawaguchi, Jhala, "Liquid Types," PLDI 2008: https://goto.ucsd.edu/~rjhala/liquid/liquid_types.pdf
- Orchard, Petricek, Mycroft, graded coeffect systems: https://dl.acm.org/doi/pdf/10.1145/3341714
- Madsen, Yee, Lhotak, "From Datalog to Flix," PLDI 2016: https://dl.acm.org/doi/10.1145/2908080.2908096
- Castagna, Duboc, Valim, "The Design Principles of the Elixir Type System," Programming 2024: https://arxiv.org/abs/2306.06391
- Castagna & Duboc, "Guard Analysis and Safe Erasure Gradual Typing for Elixir," arXiv 2024: https://arxiv.org/abs/2408.14345
- Elixir gradual set-theoretic types docs: https://hexdocs.pm/elixir/gradual-set-theoretic-types.html
- Elixir "Strong Arrows" blog (2023): https://elixir-lang.org/blog/2023/09/20/strong-arrows-gradual-typing/
- "Sound Gradual Verification with Symbolic Execution," POPL 2024: https://arxiv.org/abs/2311.07559
- Modular Collaborative Program Analysis in OPAL: https://arxiv.org/abs/2010.04476
- Gradual typing bibliography: http://samth.github.io/gradual-typing-bib/
- Pyright type inference docs: https://fossies.org/linux/pyright/docs/type-inference.md
