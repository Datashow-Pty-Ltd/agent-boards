-- A historical Done state is not proof that a visual story satisfies the
-- current measured-fidelity contract. Re-audit visual work at read time,
-- exclude non-compliant legacy work from completion totals, and provide an
-- idempotent remediation path without rewriting historical delivery records.

CREATE TABLE IF NOT EXISTS api.visual_compliance_remediations (
  source_work_item_id uuid PRIMARY KEY REFERENCES api.work_items(id) ON DELETE CASCADE,
  remediation_work_item_id uuid NOT NULL UNIQUE REFERENCES api.work_items(id) ON DELETE CASCADE,
  created_by text NOT NULL DEFAULT 'AI agent',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (source_work_item_id <> remediation_work_item_id)
);

CREATE OR REPLACE FUNCTION api.get_direct_visual_story_compliance(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  accepted_revision text;
  requirements jsonb := '[]'::jsonb;
  applicable boolean;
  compliant boolean;
  blocking_requirements jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;

  applicable := item.kind = 'story' AND api.work_item_requires_visual_evidence(item.id);
  IF NOT applicable THEN
    RETURN jsonb_build_object(
      'work_item_id', item.id,
      'item_key', item.item_key,
      'applicable', false,
      'direct_compliant', true,
      'compliant', true,
      'accepted_revision', NULL,
      'declared_screen_count', 0,
      'requirements', '[]'::jsonb,
      'blocking_requirements', '[]'::jsonb
    );
  END IF;

  SELECT criterion->>'revision' INTO accepted_revision
  FROM jsonb_array_elements(item.acceptance_criteria) criterion
  WHERE criterion->>'status' = 'passed'
    AND btrim(COALESCE(criterion->>'revision', '')) <> ''
  ORDER BY criterion->>'revision'
  LIMIT 1;

  requirements := api.visual_fidelity_gate_requirements(item.id, accepted_revision);
  SELECT COALESCE(jsonb_agg(requirement), '[]'::jsonb)
  INTO blocking_requirements
  FROM jsonb_array_elements(requirements) requirement
  WHERE NOT COALESCE((requirement->>'satisfied')::boolean, false);

  compliant := accepted_revision IS NOT NULL
    AND jsonb_array_length(item.screen_names) > 0
    AND jsonb_array_length(requirements) = jsonb_array_length(item.screen_names)
    AND jsonb_array_length(blocking_requirements) = 0;

  RETURN jsonb_build_object(
    'work_item_id', item.id,
    'item_key', item.item_key,
    'applicable', true,
    'direct_compliant', compliant,
    'compliant', compliant,
    'accepted_revision', accepted_revision,
    'declared_screen_count', jsonb_array_length(item.screen_names),
    'requirements', requirements,
    'blocking_requirements', blocking_requirements,
    'failure_reasons', jsonb_strip_nulls(jsonb_build_object(
      'accepted_revision_missing', CASE WHEN accepted_revision IS NULL THEN true END,
      'screen_inventory_missing', CASE WHEN jsonb_array_length(item.screen_names) = 0 THEN true END,
      'failed_screen_count', jsonb_array_length(blocking_requirements)
    ))
  );
END $$;

CREATE OR REPLACE FUNCTION api.get_visual_story_compliance(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  direct_status jsonb;
  remediation_id uuid;
  remediation_status jsonb;
  effective_compliant boolean;
BEGIN
  direct_status := api.get_direct_visual_story_compliance(target_work_item_id);
  IF NOT COALESCE((direct_status->>'applicable')::boolean, false)
    OR COALESCE((direct_status->>'direct_compliant')::boolean, false) THEN
    RETURN direct_status;
  END IF;

  SELECT link.remediation_work_item_id INTO remediation_id
  FROM api.visual_compliance_remediations link
  WHERE link.source_work_item_id = target_work_item_id;

  IF remediation_id IS NOT NULL THEN
    remediation_status := api.get_direct_visual_story_compliance(remediation_id);
  END IF;
  effective_compliant := COALESCE((remediation_status->>'direct_compliant')::boolean, false);

  RETURN direct_status || jsonb_build_object(
    'compliant', effective_compliant,
    'remediation_work_item_id', remediation_id,
    'remediation_compliant', effective_compliant,
    'remediation_status', remediation_status
  );
END $$;

CREATE OR REPLACE VIEW api.visual_story_compliance AS
SELECT
  item.project_id,
  item.id AS work_item_id,
  item.item_key,
  item.title,
  stage.slug AS stage_slug,
  item.completed_at,
  status.compliance,
  COALESCE((status.compliance->>'compliant')::boolean, false) AS compliant,
  COALESCE((status.compliance->>'direct_compliant')::boolean, false) AS direct_compliant,
  NULLIF(status.compliance->>'accepted_revision', '') AS accepted_revision,
  COALESCE((status.compliance->>'declared_screen_count')::integer, 0) AS declared_screen_count,
  COALESCE(jsonb_array_length(status.compliance->'blocking_requirements'), 0) AS failed_screen_count,
  NULLIF(status.compliance->>'remediation_work_item_id', '')::uuid AS remediation_work_item_id
FROM api.work_items item
JOIN api.board_stages stage ON stage.id = item.stage_id
CROSS JOIN LATERAL (
  SELECT api.get_visual_story_compliance(item.id) AS compliance
) status
WHERE item.archived_at IS NULL
  AND item.kind = 'story'
  AND api.work_item_requires_visual_evidence(item.id);

CREATE OR REPLACE VIEW api.work_item_delivery_status AS
SELECT
  item.id AS work_item_id,
  item.project_id,
  item.item_key,
  item.kind,
  stage.slug AS stage_slug,
  item.completed_at IS NOT NULL AS historically_completed,
  CASE
    WHEN item.kind = 'story' AND api.work_item_requires_visual_evidence(item.id)
      THEN COALESCE((api.get_visual_story_compliance(item.id)->>'compliant')::boolean, false)
    ELSE true
  END AS visual_compliant,
  item.completed_at IS NOT NULL AND (
    item.kind <> 'story'
    OR NOT api.work_item_requires_visual_evidence(item.id)
    OR COALESCE((api.get_visual_story_compliance(item.id)->>'compliant')::boolean, false)
  ) AS delivery_complete
FROM api.work_items item
JOIN api.board_stages stage ON stage.id = item.stage_id
WHERE item.archived_at IS NULL;

CREATE OR REPLACE VIEW api.project_summary AS
SELECT p.id AS project_id, p.project_key, p.name, p.description, p.owner, p.status, p.start_date, p.target_date,
  count(w.id) FILTER (WHERE w.archived_at IS NULL) AS total_items,
  count(w.id) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND (
        w.kind <> 'story'
        OR NOT api.work_item_requires_visual_evidence(w.id)
        OR COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
      )
  ) AS completed_items,
  count(w.id) FILTER (WHERE w.execution_state = 'running' AND w.archived_at IS NULL) AS running_items,
  count(w.id) FILTER (WHERE w.execution_state IN ('blocked','failed','waiting_for_human') AND w.archived_at IS NULL) AS blocked_items,
  COALESCE(sum(w.estimate_points) FILTER (WHERE w.archived_at IS NULL), 0) AS total_points,
  COALESCE(sum(w.estimate_points) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND (
        w.kind <> 'story'
        OR NOT api.work_item_requires_visual_evidence(w.id)
        OR COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
      )
  ), 0) AS completed_points,
  COALESCE((SELECT sum(t.input_tokens + t.output_tokens) FROM api.telemetry_events t WHERE t.project_id = p.id), 0) AS tokens,
  COALESCE((SELECT sum(t.estimated_cost_usd) FROM api.telemetry_events t WHERE t.project_id = p.id), 0) AS estimated_cost_usd,
  p.updated_at,
  count(w.id) FILTER (WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL) AS raw_completed_items,
  count(w.id) FILTER (
    WHERE w.completed_at IS NOT NULL AND w.archived_at IS NULL
      AND w.kind = 'story' AND api.work_item_requires_visual_evidence(w.id)
      AND NOT COALESCE((api.get_visual_story_compliance(w.id)->>'compliant')::boolean, false)
  ) AS noncompliant_visual_story_count,
  NOT EXISTS (
    SELECT 1 FROM api.work_items visual_item
    WHERE visual_item.project_id = p.id
      AND visual_item.archived_at IS NULL
      AND visual_item.completed_at IS NOT NULL
      AND visual_item.kind = 'story'
      AND api.work_item_requires_visual_evidence(visual_item.id)
      AND NOT COALESCE((api.get_visual_story_compliance(visual_item.id)->>'compliant')::boolean, false)
  ) AS visual_compliance_ready
FROM api.projects p LEFT JOIN api.work_items w ON w.project_id = p.id
GROUP BY p.id;

CREATE OR REPLACE FUNCTION api.ensure_visual_compliance_remediation(
  target_work_item_id uuid,
  actor_name text DEFAULT 'AI agent'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE
  source_item api.work_items;
  source_stage api.board_stages;
  existing_item api.work_items;
  remediation_item api.work_items;
  compliance jsonb;
BEGIN
  SELECT * INTO source_item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF source_item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  SELECT * INTO source_stage FROM api.board_stages WHERE id = source_item.stage_id;
  IF source_item.kind <> 'story'
    OR NOT api.work_item_requires_visual_evidence(source_item.id)
    OR source_stage.slug <> 'done' THEN
    RAISE EXCEPTION 'Visual compliance remediation applies only to a visual story in Done.' USING ERRCODE = '23514';
  END IF;

  SELECT item.* INTO existing_item
  FROM api.visual_compliance_remediations link
  JOIN api.work_items item ON item.id = link.remediation_work_item_id
  WHERE link.source_work_item_id = source_item.id;
  IF existing_item.id IS NOT NULL THEN
    RETURN NEXT existing_item;
    RETURN;
  END IF;

  compliance := api.get_visual_story_compliance(source_item.id);
  IF COALESCE((compliance->>'compliant')::boolean, false) THEN
    RAISE EXCEPTION '% already satisfies the current visual compliance contract.', source_item.item_key USING ERRCODE = '23514';
  END IF;

  SELECT * INTO remediation_item FROM api.create_backlog_item(
    target_project_id := source_item.project_id,
    item_title := 'Remediate visual compliance for ' || source_item.item_key,
    item_description := 'Re-implement and prove every declared screen from ' || source_item.item_key ||
      ' against its approved static mockup under the current measured-fidelity contract. Historical evidence remains unchanged.',
    item_kind := 'story',
    item_priority := 'urgent',
    parent_work_item_id := source_item.parent_id,
    item_assignee := NULL,
    item_acceptance_criteria := jsonb_build_array(
      jsonb_build_object(
        'statement', 'Every inherited screen has an exact-revision measured fidelity record.',
        'verification_method', 'database_assertion',
        'verification_ref', 'api.get_visual_story_compliance',
        'expected_result', 'Every declared screen is complete, same-viewport, structurally representative, and has zero unresolved P0/P1/P2 measurements.'
      ),
      jsonb_build_object(
        'statement', 'The original Done story is effectively visually compliant through this remediation.',
        'verification_method', 'database_assertion',
        'verification_ref', 'api.visual_story_compliance',
        'expected_result', source_item.item_key || ' reports compliant=true through the linked remediation story.'
      )
    ),
    item_invariants := jsonb_build_array(
      'The approved static mockup remains authoritative.',
      'Historical evidence and activity on ' || source_item.item_key || ' are not rewritten.',
      'Any unresolved P0, P1, or P2 measurement blocks promotion.'
    ),
    actor_name := actor_name
  );

  UPDATE api.work_items SET
    visual_evidence_required = true,
    screen_names = source_item.screen_names,
    labels = labels || jsonb_build_array('visual-remediation', source_item.item_key)
  WHERE id = remediation_item.id
  RETURNING * INTO remediation_item;

  INSERT INTO api.visual_compliance_remediations(source_work_item_id, remediation_work_item_id, created_by)
  VALUES (source_item.id, remediation_item.id, actor_name);

  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    source_item.project_id,
    source_item.id,
    'work_item.visual_compliance_remediation_created',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    'Created ' || remediation_item.item_key || ' to remediate visual compliance for ' || source_item.item_key,
    jsonb_build_object('remediation_work_item_id', remediation_item.id, 'remediation_item_key', remediation_item.item_key)
  );

  RETURN NEXT remediation_item;
END $$;

COMMENT ON FUNCTION api.get_visual_story_compliance(uuid) IS
  'Authoritative current-contract visual compliance, including a governed linked remediation when legacy Done work cannot be rewritten.';
COMMENT ON VIEW api.visual_story_compliance IS
  'Screen-level measured-fidelity compliance for every active visual story.';
COMMENT ON VIEW api.work_item_delivery_status IS
  'Board-facing completion status that does not equate historical Done with current visual compliance.';

GRANT SELECT, INSERT, UPDATE, DELETE ON api.visual_compliance_remediations TO web_anon;
GRANT SELECT ON api.visual_story_compliance, api.work_item_delivery_status TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_direct_visual_story_compliance(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_visual_story_compliance(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.ensure_visual_compliance_remediation(uuid, text) TO web_anon;

NOTIFY pgrst, 'reload schema';
