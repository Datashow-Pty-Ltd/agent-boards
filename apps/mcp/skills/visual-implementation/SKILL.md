---
name: agent-boards-visual-implementation
description: Implement a visual Agent Boards story from its approved mockups, design artefacts, invariants, and promotion criteria, then attach exact-revision evidence. Use only when a claimed work package reports visual_evidence_required=true.
---

# Visual implementation

Agent Boards is the control plane. The connected agent performs the implementation in the linked repository with its own coding, browser, image, and testing capabilities. Agent Boards supplies approved inputs, evidence tools, invariants, and deterministic promotion gates; it does not generate the application or operate a browser for the agent.

## Required procedure

1. Call `get_mockup_implementation_package` for the claimed story. Follow its `product-design:image-to-code` route when that host workflow is available. Treat the returned repository, approved static mockups, declared screen/state/viewports, design artefacts, acceptance criteria, invariants, measurement contract, and evidence destinations as authoritative.
2. Confirm the visual design contract is complete before building:
   - the selected visual concept is human-approved;
   - the design-concept and design-system artefacts are approved;
   - every affected screen, material state, and required viewport has an approved mockup;
   - the story's `screen_names` identify the exact screens and variants in scope.
3. If any required input is missing or contradictory, add a concise clarification comment and block the work item. Do not invent an approval or silently substitute a design.
4. Implement in the linked repository. Preserve its architecture, router, component system, accessibility conventions, and existing test strategy unless the work package explicitly changes them.
5. Implement the approved visual hierarchy and interaction states, not merely the wording. Cover loading, empty, error, focus, hover, disabled, reduced-motion, responsive, and touch behaviour when they are in scope.
6. Run the deterministic checks available in the repository. Recommend missing unit, regression, accessibility, or interaction checks; establish them when practical, or record an explicit user waiver through Agent Boards.
7. For each declared screen and viewport, capture an implementation screenshot from the exact Build revision and attach it with `attach_work_item_asset` as `implementation_screenshot`. When interaction is material, mark `interaction_evidence_required=true`; the later Validate walkthrough must show a visible pointer/touch indicator and continuous, deliberate 1× interaction rather than a montage.
8. Record implementation evidence for that exact revision before promoting from Build. Never attach unrelated, stale, fabricated, or hand-edited evidence.

## Boundaries

- Do not self-approve visual concepts, design artefacts, or screen mockups.
- Do not substitute a live page or a newly rendered reference for the approved static mockup resolved by the package.
- Do not declare visual fidelity from memory or qualitative judgement alone.
- Do not require visual evidence for a non-visual story.
- If the host lacks the native capability needed to implement or capture the required evidence, block the item with the missing capability; Agent Boards must not execute the work on the agent's behalf.

