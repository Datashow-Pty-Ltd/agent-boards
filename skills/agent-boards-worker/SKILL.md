---
name: agent-boards-worker
description: Work an Agent Boards project as an autonomous dependency-aware backlog loop. Use when the user asks Codex to claim available Agent Boards stories, execute their tasks, progress governed stages, or continue until no work can advance.
---

# Agent Boards Worker

Use the `agent-boards` MCP server as the authoritative project record and queue. The code, tests, review, and integration happen in the active repository; the board records availability, requirements, state, evidence, and decisions.

## Before claiming

- Identify the requested Agent Boards project with `list_projects`; do not guess from a similarly named repository.
- Confirm the active workspace is the repository in which the claimed work should be implemented.
- Do not claim work for a read-only request such as reviewing, explaining, or reporting backlog status.
- Register once for the project with `register_worker`, using a stable unique lowercase handle and the correct client type (`codex`, `claude`, or `other`). Retain the returned immutable worker ID and one-time resume token for this work session. If retained credentials already exist, verify them with `resume_worker` instead of registering again.
- Treat the resume token as a private credential. Never put it in source files, comments, evidence, board records, logs, or user-facing output, and never use another worker's credentials. A duplicate handle must be resumed with its original credentials or replaced with a genuinely different handle.
- Use `claim_next_ready_work_item` with the worker ID and resume token as the atomic queue entry point. Do not select a card manually or claim multiple stories speculatively. Pass the same credentials to claim, move, heartbeat, block, and release operations. Parallel Codex and Claude workers are expected to run independent loops; PostgreSQL prevents them from receiving the same story.
- Treat `owner` as durable accountability and `assignee` as the current claim holder. Do not overwrite another active worker's claim. Use `set_work_item_owner` when a person explicitly assigns or transfers responsibility.
- Treat a claim as a renewable lease. Call `heartbeat_work_item` with the claimed story ID and registered worker credentials at least every five minutes during long-running work, including while waiting on lengthy builds or test suites. Never take over another worker's idle claim yourself; only a person may authorize a transfer or release in Agent Boards.

## Work loop

Repeat the following sequence within the user's requested scope:

1. Claim the next dependency-ready story.
2. If the result is `no_ready_work`, stop. Report whether the project is complete or remaining work is blocked; do not poll in a tight loop.
3. Treat the returned work package as the focused contract:
   - the story defines the intended outcome;
   - child tasks define the required pieces of work;
   - invariants must remain true throughout implementation;
   - story acceptance criteria define the finished behaviour;
   - attached visual references and mockups define the intended presentation;
   - promotion acceptance criteria define what is required to enter the next stage.
4. Perform the actual work in the repository. Keep the board synchronized as durable evidence becomes true, not in anticipation of it.
   - Renew the claim with `heartbeat_work_item` at least every five minutes until the story is Done, blocked, or deliberately released.
   - After each child task is actually implemented, call `complete_task` with a concise outcome summary.
   - Child tasks do not traverse the story stage sequence; never use `move_work_item` or a generic execution-state update to complete them.
5. Before each stage transition, call `get_work_item_context` and satisfy every blocking promotion criterion. Record the requested evidence, then move exactly one legal stage.
6. If `design_card_type` is set, treat the story as design-only. Complete its child tasks, obtain every required human design approval, call `get_design_card_completion_requirements`, and then call `complete_design_card` from Plan. Do not move it into Build and do not claim mockups are implemented application evidence.
7. Complete a software story's child tasks with `complete_task` before promoting the story from Review to Merge.
8. After Done, immediately claim the next eligible story and continue.

## Governed stage order

Move exactly one stage at a time. Never compress review, merge, or target-branch verification into one update:

Design-only stories (`design_card_type` is `visual_concept` or `screen_mockup`) use `Backlog → Analyse → Plan → Done`. The dedicated `complete_design_card` operation is the only Plan → Done transition: it requires the relevant human approvals and records a durable design-contract revision without source, test, review, merge, or regression evidence. The stages below apply to implementation stories.

1. `Backlog → Analyse` after deterministic acceptance criteria and prerequisites are ready.
2. `Analyse → Plan` after analysis evidence records scope, constraints, risks, and dependencies.
3. `Plan → Build` after the implementation and verification plan is recorded and the required visual design contract is approved and attached.
4. `Build → Validate` after implementation evidence identifies the exact revision and required implementation screenshots are attached.
5. `Validate → Review` after every acceptance criterion passes for that same exact revision and required visual validation is attached.
6. `Review → Merge` after the validated revision is approved and review evidence records `details.unresolved_findings` as `0`.
7. `Merge → Post-merge verification` after merge evidence links the merged revision to the exact reviewed revision.
8. `Post-merge verification → Done` after the merged revision has passing regression evidence. If the repository regression suite is unavailable and the user explicitly waives it, record the passing alternative check in regression evidence as `details.alternative_check`; the waiver alone is not enough. Every child task must also be Done.

## Evidence and quality constraints

- Record only evidence that was actually observed. Never fabricate commands, test results, revisions, approvals, merge results, URLs, or human decisions.
- Record deterministic story acceptance results against the exact tested revision.
- Preserve the distinction between a reviewed source revision and the merged revision when the repository uses Git or another integration system.
- Project quality constraints are authoritative. Required constraints must pass. Recommended unit or regression checks must not be silently ignored: establish a deterministic required check when practical, or surface the recommendation for a decision.
- Waive a project quality constraint only when the user explicitly authorizes the waiver. Record the deciding person and their reason.
- If the repository cannot provide evidence required by the current promotion criteria, block the story with the concrete missing capability or decision rather than pretending the gate passed.

## Visual changes

- Image and video evidence is conditional. Require it only when the claimed work package reports `visual_evidence_required: true`, either because the story itself is marked as a visual change or because it inherits the marker from its parent feature.
- Do not infer that every story in a web, mobile, or desktop project is visual. Backend, data, API, infrastructure, refactoring, and other non-visual stories do not need screenshots, mockups, visual diffs, or recordings when the marker is false.
- During Backlog or Analyse, if the story's outcome actually changes a user-visible interface or interaction and the marker appears to be missing, set `visualEvidenceRequired` to true with `update_work_item` before proceeding. Do not add visual evidence merely to make an unrelated gate appear complete.
- When `visual_evidence_required` is true, treat visual design as part of the story contract, not as optional polish.
- During Plan, inspect existing visual references. Create a mockup or wireframe and attach it with `attach_work_item_asset` before entering Build. Use image generation when it materially improves a UI design decision; do not generate decorative imagery merely to satisfy the gate.
- Treat a live HTML mockup as an editable authoring source only, never as the durable mockup or validation evidence. Before it can satisfy a promotion gate or be submitted for approval, render the exact declared screen/state at the declared viewport, capture a static image, and attach that image to the story as `mockup` or `wireframe` with the matching `screenName` and viewport metadata. Record the HTML source URL, file, or revision in the caption when useful, but never attach or depend on the live page in place of the captured image.
- Human approval applies to the attached captured image, not to a dynamically rendered URL. If the HTML changes materially after capture, create and attach a new captured image and obtain a new approval before implementation continues. When no captured image exists, treat the visual contract as incomplete and block Plan → Build rather than relying on runtime rendering.
- During Build, capture the implemented interface at the relevant viewport and attach it as `implementation_screenshot` for the exact implementation revision.
- Before visual Build work, call `get_mockup_implementation_package` and use its `product-design:image-to-code` routing metadata, approved static mockups, declared screen/state/viewports, design artefacts, measurement contract, and evidence destinations. Do not reconstruct these inputs from chat history.
- During Validate, call `get_visual_critique_package` for the exact screen and revision, compare the bound implementation with the approved static source, and attach `visual_validation` or `visual_diff` for that same revision and viewport. Record the result with `record_visual_critique`, including structured P0-P3 findings and measurements; do not substitute a prose-only verdict.
- Treat visual fidelity as a measurement exercise, not a subjective impression. Before recording a passing visual validation, create and retain a reference-versus-implementation measurement manifest for the exact viewport and state. At minimum it must cover: typography (family, weight, size, line height and letter spacing for each material text style); element geometry (x/y position, width, height and border radius for every major element and visible control); spacing (page insets, section gaps, component gaps, padding and margins that define the layout rhythm); and colour (sampled foreground, background, border and state colours, with an explicit colour-distance tolerance when antialiasing or texture prevents exact equality). Include connector points, curves, imagery bounds or other screen-specific geometry when they materially define the approved design.
- Every measurement entry must name the element and property, record reference and implementation values, unit, allowed tolerance, observed delta, severity, measurement source or method, and whether it is within tolerance. Derive unresolved P0/P1/P2 counts from out-of-tolerance entries; never enter zero counts by judgment when the measurements show a material difference.
- A side-by-side comparison that visibly exposes material differences in font metrics, position, size, spacing, radius, colour, shape, crop, or alignment is a failed validation. Compositionally similar, recognisably inspired by, or directionally correct are not passing standards. Do not set `representsApprovedDesign` or `structuralMatch` true while any material difference remains outside its declared tolerance.
- Use overlays, image sampling, pixel or perceptual colour comparison, DOM/computed-style inspection, and bounding-box measurements as appropriate. Do not rely on unaided visual estimation for values that the browser or an image-analysis tool can measure. Record the tools and sampling method so another reviewer can reproduce the result.
- Tolerances must be declared before judging the result and must be narrow enough to preserve the approved design. Do not widen a tolerance after seeing a failure merely to make the gate pass. Exact design tokens such as font family, font weight, font size, radius, and flat colours should normally require exact equality; image-derived positions and textured or antialiased colours may use a small documented tolerance.
- Required measurement coverage is itself a blocking condition. If typography, geometry, spacing, controls, colours, or screen-specific defining shapes have not been measured, leave the fidelity gate unsatisfied even when the comparison appears close.
- When the design originated as HTML, validation must use the approved captured image asset as its source of truth. Do not re-render the live HTML during validation and silently use the new output as the reference. `comparisonMethod: html_reference` records the reference's provenance only; `sourceMockupAssetId` must still identify the attached, human-approved static capture.
- During Validate, require a recording only when the story's acceptance scenario is visually demonstrable in the running application. Do not require video for backend-only, domain, data, infrastructure, or other non-visual changes. For visually demonstrable work, capture the application exercising the relevant acceptance scenarios. Prefer the host agent's native screen-recording capability; use browser recording as a fallback. Upload the captured file bytes with `attach_validation_recording`—do not substitute a link—linked to the exact revision and the test evidence record it demonstrates.
- Prefer real application screenshots for implementation and validation evidence. Generated images are design inputs, never proof that the built UI works.
- Use `set_primary_work_item_asset` to select the image that best communicates the story on its board card.

## Design-first application work

- For a new web/mobile/desktop application or a material redesign, run a governed divergence-and-convergence design track inside Analyse and Plan. Do not treat one generated screenshot as a complete design process.
- Define users, key journeys or flows, information architecture/navigation, the screen inventory, important states, and target viewport variants during Analyse. Screen inventory entries should be specific enough to approve independently, for example `Results · empty · mobile`.
- Create a dedicated story with `designCardType: visual_concept`. Attach the product references and at least two meaningfully different concept options. Use image generation when it helps explore a real design decision. Do not create superficial colour swaps merely to reach the option count.
- Stop for human selection. A person records the selection with `approve_visual_concept`; an autonomous worker must never call an approval tool based on its own preference or pretend that primary/candidate imagery is approved.
- After selection, complete the stable `design-concept` project artefact. It must record the selected direction and rationale, experience/design principles, key journeys or flows, information architecture/navigation, screens and important states, interaction/motion language, and responsive intent. A person must approve it with `approve_design_artefact(artefact: design_concept)`.
- Derive the stable `style-guide` / `design_system` artefact from the approved concept. It must define the project design DNA: colour/material tokens, typography, spacing and shape, components and interaction states, interaction/motion rules, responsive behaviour, and accessibility constraints. A person must approve it with `approve_design_artefact(artefact: design_system)`.
- Create one or more stories with `designCardType: screen_mockup`, or declare `screenNames` directly on visual implementation stories. Attach each mockup with the exact matching `screenName`. A person approves each reference with `approve_screen_mockup` only after the concept artefact and design system are approved.
- HTML-based screen mockups follow the same governed path: capture each declared screen, important state, and viewport variant to a static image; attach every capture to the relevant story; and obtain approval on those captured assets. A live preview may accompany the card for convenience, but it cannot replace any required attached image.
- Require an approved mockup for every declared screen, important state, and viewport variant. Empty, loading, error, disabled, permission, completion, destructive-confirmation, and responsive states count when users can encounter them; do not invent irrelevant variants.
- Do not promote a visual story from Plan to Build until the database reports all design-governance promotion requirements satisfied. If the concept, an artefact, or a screen mockup awaits human authority, add a concise clarification comment and block the card instead of choosing on the user's behalf.
- Treat the approved design concept, design system, and screen mockups as the visual contract during Build and Validate. Any material departure requires a revised artefact/mockup and a newly recorded human approval before implementation continues.
- Once every design-card task and required human approval is complete, inspect `get_design_card_completion_requirements` and close the card with `complete_design_card`. The actual implementation belongs to separate stories that consume these approved assets and follow the full software stage order.

## Blocking and stopping

- When a story cannot progress, call `block_work_item` with the specific impediment and then claim the next eligible story.
- Use `release_work_item` only when stopping work without a real blocker; do not use release to hide a failed or waiting state.
- Stop when the queue returns `no_ready_work`, the user asks to stop, or no further safe action is possible within the granted authority.
- Summarize completed stories, blocked stories and reasons, evidence recorded, and the final queue outcome.
