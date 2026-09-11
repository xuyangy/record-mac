# Specification Quality Checklist: Unified Mac Screen Recorder

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-09-11
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`

### Outstanding

None. All 16 items pass.

### Resolved

- **Licensing posture** (was the sole open question): the project adopts **AGPL-3.0** for the
  combined work, the only license under which all three sources can be combined, since
  Apache-2.0 material may be taken into an AGPL-3.0 work but not the reverse. Upstream code may
  therefore be reused directly. No functional requirement changed — the decision governs how
  FR-016, FR-021, FR-055 and FR-066 are built, not what they do. Obligations are recorded under
  Dependencies in the spec, satisfying the constitution's requirement that license conflicts be
  resolved before derived code is committed.

### Judgement calls recorded during validation

- **Named platform capabilities**: Out of Scope names the operating system's presenter overlay,
  and Assumptions names the three upstream projects and their licenses. These are scope and
  provenance constraints inherited from the request and the constitution, not implementation
  choices, so "no implementation details" is treated as passing. No framework, language, or
  interface is named anywhere in the requirements.
- **Requirement tightening**: FR-031, FR-036, and FR-040 were rewritten during validation to
  replace subjective wording ("natural", "remain legible") with observable behaviour, so that
  each fails or passes a test unambiguously.
- **Acceptance criteria coverage**: acceptance scenarios are attached to user stories rather
  than to each of the 72 requirements individually. Every requirement traces to at least one
  story, and the Upstream Capability Coverage table gives the reverse mapping.
- **Hardware-gated behaviour** is specified as a requirement (FR-071) rather than left to the
  plan, so that degradation is testable rather than incidental.
