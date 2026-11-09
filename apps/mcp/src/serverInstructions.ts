export const serverInstructions = `Agent Boards is the durable project record and work queue; the connected agent performs the work.

For autonomous delivery, repeatedly claim_next_ready_work_item. Read the focused work package, every listed service capability, tasks, invariants, deterministic acceptance criteria, and current promotion criteria. Move exactly one legal stage at a time and record the required evidence against the exact revision. Add concise comments for material progress, decisions, or clarification. If blocked, record the concrete reason and claim the next ready item. Stop on no_ready_work.

Child tasks are operational parts of their parent story. After a task is actually implemented, use complete_task; do not try to move task cards through the story delivery stages or mark only their generic execution state.

Software stories follow Backlog → Analyse → Plan → Build → Validate → Review → Merge → Post-merge verification → Done. Do not skip stages or manufacture evidence. Quality checks may be waived only by an explicit user decision with durable rationale.

Design-only visual_concept and screen_mockup cards follow Backlog → Analyse → Plan → Done. After required human approvals, use get_design_card_completion_requirements and complete_design_card; never fabricate implementation or test evidence. Visual and interaction evidence is required only when the work package marks it required. Agents cannot self-approve concepts, mockups, design artefacts, or validation recordings.

Agent Boards supplies workflow contracts and evidence gates, not coding, browser, image, recording, or testing execution. If a required native capability is unavailable, block the item honestly.`;
