-- A fresh installation starts with one self-contained demo project. Existing
-- installations are never modified: the demo is created only when there are
-- no projects at all after the schema migrations have completed.

DO $$
DECLARE
  demo_project api.projects;
  demo_board uuid;
  backlog_stage uuid;
  analyse_stage uuid;
  plan_stage uuid;
  build_stage uuid;
  onboarding_feature uuid;
  delivery_feature uuid;
  release_feature uuid;
  connect_story uuid;
  tour_story uuid;
  claim_story uuid;
  movement_story uuid;
  container_story uuid;
  release_story uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM api.projects) THEN
    RETURN;
  END IF;

  SELECT * INTO demo_project
  FROM api.create_project(
    'Agent Boards Demo',
    'DEMO',
    'A sample product delivery project showing governed work, evidence and agent collaboration.',
    'Demo team'
  );

  UPDATE api.projects
  SET target_date = current_date + 21
  WHERE id = demo_project.id;

  SELECT id INTO demo_board FROM api.boards WHERE project_id = demo_project.id;
  SELECT id INTO backlog_stage FROM api.board_stages WHERE board_id = demo_board AND slug = 'backlog';
  SELECT id INTO analyse_stage FROM api.board_stages WHERE board_id = demo_board AND slug = 'analyse';
  SELECT id INTO plan_stage FROM api.board_stages WHERE board_id = demo_board AND slug = 'plan';
  SELECT id INTO build_stage FROM api.board_stages WHERE board_id = demo_board AND slug = 'build';

  INSERT INTO api.work_items(
    project_id, board_id, stage_id, item_key, kind, title, description,
    priority, estimate_points, labels, position
  ) VALUES (
    demo_project.id, demo_board, backlog_stage, 'DEMO-1', 'feature',
    'Guided onboarding',
    'Help a new team connect an agent and understand the governed workflow.',
    'high', 5, '["onboarding"]', 0
  ) RETURNING id INTO onboarding_feature;

  INSERT INTO api.work_items(
    project_id, board_id, stage_id, item_key, kind, title, description,
    priority, estimate_points, labels, position
  ) VALUES (
    demo_project.id, demo_board, backlog_stage, 'DEMO-2', 'feature',
    'Collaborative delivery board',
    'Keep humans and coding agents aligned on ready work, progress and evidence.',
    'urgent', 8, '["workflow"]', 1
  ) RETURNING id INTO delivery_feature;

  INSERT INTO api.work_items(
    project_id, board_id, stage_id, item_key, kind, title, description,
    priority, estimate_points, labels, position
  ) VALUES (
    demo_project.id, demo_board, backlog_stage, 'DEMO-3', 'feature',
    'Release readiness',
    'Package a documented, verifiable release for operators.',
    'medium', 8, '["release"]', 2
  ) RETURNING id INTO release_feature;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, estimate_points, invariants,
    position
  ) VALUES (
    demo_project.id, demo_board, onboarding_feature, backlog_stage, 'DEMO-4',
    'story', 'Connect a coding agent',
    'Configure the MCP endpoint and confirm the agent can list and claim ready work.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'The configured agent lists this demo project through MCP.',
      'verification_method', 'command',
      'verification_ref', 'MCP list_projects',
      'expected_result', 'The project key DEMO is returned.'
    ))),
    'high', 2, '["The board remains the durable source of truth."]', 3
  ) RETURNING id INTO connect_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, estimate_points, position
  ) VALUES (
    demo_project.id, demo_board, onboarding_feature, backlog_stage, 'DEMO-5',
    'story', 'Show the governed workflow tour',
    'Explain stages, promotion evidence and the autonomous ready-work loop.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'The tour presents all workflow concepts.',
      'verification_method', 'automated_test',
      'verification_ref', 'tour.spec.ts',
      'expected_result', 'Every tour step renders and can be advanced.'
    ))),
    'medium', 3, 4
  ) RETURNING id INTO tour_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, progress, execution_state,
    assignee, estimate_points, invariants, position
  ) VALUES (
    demo_project.id, demo_board, delivery_feature, analyse_stage, 'DEMO-6',
    'story', 'Claim the next ready story',
    'Return the highest-priority story with no incomplete prerequisites.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'Ready work is claimed atomically.',
      'verification_method', 'database_assertion',
      'verification_ref', 'claim_next_ready_work_item',
      'expected_result', 'Concurrent claims cannot return the same story.'
    ))),
    'urgent', 'in_progress', 'running', 'Codex', 3,
    '["A story with incomplete prerequisites is never returned."]', 0
  ) RETURNING id INTO claim_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, progress, execution_state,
    assignee, estimate_points, visual_evidence_required, screen_names,
    interaction_evidence_required, position
  ) VALUES (
    demo_project.id, demo_board, delivery_feature, plan_stage, 'DEMO-7',
    'story', 'Animate one-stage card movement',
    'Move only the affected card when a stage event arrives.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'A card moves exactly one visible lane per stage event.',
      'verification_method', 'visual_baseline',
      'verification_ref', 'delivery-board-card-movement',
      'expected_result', 'The card eases between adjacent lanes without refreshing the board.'
    ))),
    'high', 'in_progress', 'running', 'Claude', 3, true,
    '["Delivery board"]', true, 0
  ) RETURNING id INTO movement_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, progress, execution_state,
    assignee, estimate_points, position
  ) VALUES (
    demo_project.id, demo_board, release_feature, build_stage, 'DEMO-8',
    'story', 'Verify the container stack',
    'Start the complete stack from a clean clone and check every public health endpoint.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'All public services become healthy.',
      'verification_method', 'http_assertion',
      'verification_ref', '/health,/mcp/health,/intelligence/health',
      'expected_result', 'Gateway, MCP and intelligence endpoints return HTTP 200.'
    ))),
    'high', 'in_progress', 'running', 'Codex', 4, 0
  ) RETURNING id INTO container_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    description, acceptance_criteria, priority, estimate_points, position
  ) VALUES (
    demo_project.id, demo_board, release_feature, backlog_stage, 'DEMO-9',
    'story', 'Publish the alpha release',
    'Create signed release metadata and reproducible source archives.',
    api.normalize_acceptance_criteria(jsonb_build_array(jsonb_build_object(
      'statement', 'The release archive matches the tagged source.',
      'verification_method', 'command',
      'verification_ref', 'pnpm release:verify:public',
      'expected_result', 'Verification completes without a mismatch.'
    ))),
    'medium', 4, 5
  ) RETURNING id INTO release_story;

  INSERT INTO api.work_items(
    project_id, board_id, parent_id, stage_id, item_key, kind, title,
    priority, position
  ) VALUES
    (demo_project.id, demo_board, connect_story, backlog_stage, 'DEMO-10', 'task', 'Add the MCP server configuration', 'medium', 0),
    (demo_project.id, demo_board, connect_story, backlog_stage, 'DEMO-11', 'task', 'Confirm the agent can list projects', 'medium', 1),
    (demo_project.id, demo_board, tour_story, backlog_stage, 'DEMO-12', 'task', 'Write the five tour steps', 'medium', 0),
    (demo_project.id, demo_board, tour_story, backlog_stage, 'DEMO-13', 'task', 'Test responsive tour navigation', 'medium', 1),
    (demo_project.id, demo_board, claim_story, analyse_stage, 'DEMO-14', 'task', 'Resolve dependency-ready work', 'medium', 0),
    (demo_project.id, demo_board, claim_story, analyse_stage, 'DEMO-15', 'task', 'Lock the atomic claim transaction', 'medium', 1),
    (demo_project.id, demo_board, movement_story, plan_stage, 'DEMO-16', 'task', 'Queue discrete movement events', 'medium', 0),
    (demo_project.id, demo_board, movement_story, plan_stage, 'DEMO-17', 'task', 'Capture the interaction walkthrough', 'medium', 1),
    (demo_project.id, demo_board, container_story, build_stage, 'DEMO-18', 'task', 'Build every container', 'medium', 0),
    (demo_project.id, demo_board, container_story, build_stage, 'DEMO-19', 'task', 'Probe public health endpoints', 'medium', 1),
    (demo_project.id, demo_board, release_story, backlog_stage, 'DEMO-20', 'task', 'Generate release checksums', 'medium', 0),
    (demo_project.id, demo_board, release_story, backlog_stage, 'DEMO-21', 'task', 'Verify the source archive', 'medium', 1);

  INSERT INTO api.work_item_evidence(
    project_id, work_item_id, evidence_type, outcome, summary, details,
    actor_name, created_at
  ) VALUES
    (demo_project.id, movement_story, 'analysis', 'recorded',
      'Confirmed the card event contract, adjacent-stage ordering and required interaction evidence.',
      '{}', 'Demo agent', now() - interval '4 minutes'),
    (demo_project.id, container_story, 'analysis', 'recorded',
      'Confirmed clean-clone scope, public endpoints and deterministic health assertions.',
      '{}', 'Demo agent', now() - interval '3 minutes'),
    (demo_project.id, container_story, 'plan', 'recorded',
      'Build the stack from a clean clone, exercise REST and MCP, then restart with persistent volumes.',
      '{}', 'Demo agent', now() - interval '2 minutes');

  INSERT INTO api.work_item_comments(
    work_item_id, actor_type, actor_name, body, created_at
  ) VALUES
    (claim_story, 'agent', 'Codex',
      'Dependency-ready selection and atomic claim rules are being verified.',
      now() - interval '3 minutes'),
    (movement_story, 'agent', 'Claude',
      'The adjacent-stage animation plan is recorded; visual approval remains required before Build.',
      now() - interval '2 minutes'),
    (container_story, 'agent', 'Codex',
      'Clean-room build started; health checks will be captured against the exact release.',
      now() - interval '1 minute');

  UPDATE api.activity_events
  SET created_at = now() - interval '10 minutes'
  WHERE project_id = demo_project.id AND event_type = 'project.created';

  INSERT INTO api.activity_events(
    project_id, work_item_id, event_type, actor_type, actor_name, summary,
    details, created_at
  ) VALUES
    (demo_project.id, claim_story, 'work_item.claimed', 'agent', 'Codex',
      'Claimed next ready story DEMO-6', '{}', now() - interval '3 minutes'),
    (demo_project.id, movement_story, 'work_item.stage_changed', 'agent', 'Claude',
      'Analysis recorded; one-stage card movement is ready to plan.',
      '{"from":"analyse","to":"plan"}', now() - interval '2 minutes'),
    (demo_project.id, container_story, 'work_item.stage_changed', 'agent', 'Codex',
      'Plan recorded; clean-room container verification is running.',
      '{"from":"plan","to":"build"}', now() - interval '1 minute');

  UPDATE api.project_artifacts
  SET
    content = CASE artifact_key
      WHEN 'project-brief' THEN $brief$
# Agent Boards Demo

Demonstrate how a human team and connected coding agents share one governed project record. The demo covers dependency-ready work, deterministic acceptance criteria, stage evidence, visible delivery flow and release verification.
$brief$
      WHEN 'prd' THEN $prd$
# Product requirements

- A person can understand current delivery from the overview and board.
- An MCP-connected agent can claim only dependency-ready stories.
- Every story carries deterministic acceptance criteria and promotion evidence.
- Visual work remains gated by approved design and observable validation.
$prd$
      WHEN 'architecture' THEN $architecture$
# Architecture

The demo uses the same PostgreSQL record through the React UI, PostgREST API and Streamable HTTP MCP server. OpenResty exposes the services on one origin; repository intelligence remains read-only and revision-pinned.
$architecture$
      WHEN 'risk-register' THEN E'| ID | Risk | Likelihood | Impact | Mitigation | Owner | Status |\n| --- | --- | --- | --- | --- | --- | --- |\n| R-1 | Demo repository is illustrative only | Low | Low | Replace it when creating a real project | Demo team | Open |'
      WHEN 'issue-register' THEN E'| ID | Issue | Priority | Owner | Status | Resolution |\n| --- | --- | --- | --- | --- | --- |'
      ELSE content
    END,
    status = CASE WHEN artifact_key IN (
      'project-brief', 'prd', 'architecture', 'risk-register', 'issue-register'
    ) THEN 'current' ELSE status END,
    created_by = CASE WHEN artifact_key IN (
      'project-brief', 'prd', 'architecture', 'risk-register', 'issue-register'
    ) THEN 'Demo setup' ELSE created_by END
  WHERE project_id = demo_project.id;

  PERFORM api.set_project_repository(
    demo_project.id,
    'https://github.com/octocat/Hello-World',
    'master',
    'Demo setup'
  );
END $$;

NOTIFY pgrst, 'reload schema';
