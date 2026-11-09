---
name: agent-boards-visual-validation
description: Validate an exact implementation revision against approved Agent Boards mockups with reproducible measurements and durable image or video evidence. Use only when a visual work item is in Validate.
---

# Visual validation

Agent Boards owns the evidence contract and promotion gate. The connected agent performs inspection and measurement with its own browser, DOM, screenshot, image-comparison, and testing capabilities, then records the result through Agent Boards.

## Required procedure

1. Call `get_visual_critique_package` immediately before validation with the declared screen and exact implementation revision. Follow its `product-design:design-qa` route when that host workflow is available. Use only the approved static source, rendered implementation, and equal viewport bound by the returned package.
2. Reproduce the same declared screen state, viewport width, viewport height, device scale, data state, and relevant interaction state. A comparison across different states or viewports is invalid.
3. Capture the implementation at the exact revision. Attach the screenshot as `visual_validation` or a durable diff as `visual_diff`.
4. When `interaction_evidence_required=true`, capture a real interaction walkthrough and attach it with `attach_validation_recording`. The recording must:
   - show the pointer or an explicit touch indicator throughout the interaction;
   - run continuously at 1× speed without jump cuts, time compression, or a slideshow of states;
   - begin from a recognizable initial state and show each user action producing its visible result;
   - pause deliberately after each action so a reviewer can inspect the result;
   - include at least two timestamped `walkthroughSteps`, each with the action and deterministic expected result;
   - use the exact accepted revision and link to passing test evidence for that revision.
   A rapid flash of screens is failed evidence even if the video file is technically playable. Wait for a person to approve the walkthrough; never self-approve it.
5. Compare source and implementation using the host's available visual and browser tooling. Measure, at minimum:
   - typography: family, size, weight, line height, and letter spacing;
   - geometry: x, y, width, height, and border radius for major elements and controls;
   - spacing: page inset, section gap, and component gap;
   - colour: text, background, and border colours;
   - screen-defining geometry such as connectors, crop, or alignment when present.
6. Call `record_visual_critique` for every declared screen. Include structured P0-P3 findings and the complete measurement manifest. Each measurement must name the element and property and include reference value, implementation value, unit, predeclared tolerance, observed delta, severity, and reproducible method.
7. Treat every visible material discrepancy as a failure until corrected. A side-by-side view is evidence, not a subjective approval. Agent Boards derives tolerance and unresolved severity counts server-side.
8. Re-run validation after any implementation or evidence change. Only promote when the gate reports complete coverage and zero unresolved P0, P1, or P2 discrepancies, plus an approved walkthrough when interaction evidence is required.

## Boundaries

- Never validate a different revision from the one being reviewed.
- Never bypass the critique package's source/rendered binding or record a prose-only verdict.
- Never mark `sameViewport`, `representsApprovedDesign`, or `structuralMatch` true without direct evidence.
- Never fabricate measurements, screenshots, recordings, or approvals.
- Never use a cut montage, accelerated capture, automatic route cycling, or screen-state slideshow as interaction evidence.
- Never hide the pointer/touch indicator or omit the action that caused the visible result.
- Do not require image or video evidence for a non-visual story.
- If the host lacks the native capability needed to inspect, measure, or capture the required evidence, block the item with the missing capability; Agent Boards remains the record and gate, not the execution environment.

