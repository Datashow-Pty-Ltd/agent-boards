-- Visual proof is conditional on an explicit work-item classification. Features
-- can mark an entire slice as visual; child stories inherit that requirement.

CREATE OR REPLACE FUNCTION api.work_item_requires_visual_evidence(target_work_item_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(item.visual_evidence_required, false)
    OR COALESCE(parent.visual_evidence_required, false)
  FROM api.work_items item
  LEFT JOIN api.work_items parent
    ON parent.id = item.parent_id AND item.kind = 'story' AND parent.kind = 'feature'
  WHERE item.id = target_work_item_id
$$;

CREATE OR REPLACE FUNCTION api.set_visual_evidence_requirement(
  target_work_item_id uuid,
  required boolean,
  actor_name text DEFAULT 'You'
) RETURNS SETOF api.work_items
LANGUAGE plpgsql AS $$
DECLARE item api.work_items; stage api.board_stages;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id FOR UPDATE;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind NOT IN ('feature', 'story') THEN
    RAISE EXCEPTION 'Only a feature or story can be marked as a visual change.' USING ERRCODE = '23514';
  END IF;
  SELECT * INTO stage FROM api.board_stages WHERE id = item.stage_id;
  IF stage.slug NOT IN ('backlog', 'analyse', 'plan') THEN
    RAISE EXCEPTION 'The visual change marker cannot change after Build begins.' USING ERRCODE = '23514';
  END IF;
  IF item.kind = 'feature' AND EXISTS (
    SELECT 1
    FROM api.work_items child
    JOIN api.board_stages child_stage ON child_stage.id = child.stage_id
    WHERE child.parent_id = item.id AND child.kind = 'story'
      AND child_stage.slug NOT IN ('backlog', 'analyse', 'plan')
  ) THEN
    RAISE EXCEPTION 'The feature visual change marker cannot change after a child story begins Build.' USING ERRCODE = '23514';
  END IF;
  UPDATE api.work_items SET visual_evidence_required = required
  WHERE id = item.id RETURNING * INTO item;
  INSERT INTO api.activity_events(project_id, work_item_id, event_type, actor_type, actor_name, summary, details)
  VALUES (
    item.project_id, item.id, 'work_item.visual_requirement_changed',
    CASE WHEN actor_name = 'You' THEN 'human' ELSE 'agent' END,
    actor_name,
    CASE WHEN required THEN 'Marked ' ELSE 'Cleared ' END || item.item_key ||
      CASE WHEN required THEN ' as a visual change' ELSE ' visual change marker' END,
    jsonb_build_object('visual_change', required, 'visual_evidence_required', required)
  );
  RETURN NEXT item;
END $$;

CREATE OR REPLACE FUNCTION api.enforce_visual_evidence_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE previous_stage api.board_stages; next_stage api.board_stages; implementation_revision text; accepted_revision text;
BEGIN
  IF NEW.stage_id = OLD.stage_id OR OLD.kind <> 'story' OR NOT api.work_item_requires_visual_evidence(OLD.id) THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.slug = 'build' AND previous_stage.slug = 'plan' AND NOT EXISTS (
    SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id AND asset.asset_type IN ('mockup','wireframe')
  ) THEN
    RAISE EXCEPTION 'Visual story cannot enter Build without an attached mockup or wireframe.' USING ERRCODE = '23514';
  END IF;
  IF next_stage.slug = 'validate' THEN
    SELECT evidence.revision INTO implementation_revision FROM api.work_item_evidence evidence
    WHERE evidence.work_item_id = OLD.id AND evidence.evidence_type = 'implementation'
      AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
    ORDER BY evidence.created_at DESC LIMIT 1;
    IF implementation_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type = 'implementation_screenshot' AND asset.revision = implementation_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Validate without an implementation screenshot for the exact implementation revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  IF next_stage.slug = 'review' THEN
    SELECT criterion->>'revision' INTO accepted_revision FROM jsonb_array_elements(OLD.acceptance_criteria) criterion LIMIT 1;
    IF accepted_revision IS NULL OR NOT EXISTS (
      SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = OLD.id
        AND asset.asset_type IN ('visual_validation','visual_diff') AND asset.revision = accepted_revision
    ) THEN
      RAISE EXCEPTION 'Visual story cannot enter Review without visual validation for the accepted revision.' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION api.get_work_item_context_with_visuals(target_work_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  item api.work_items;
  parent_item api.work_items;
  context jsonb;
  assets jsonb;
  requirements jsonb;
  current_stage_slug text;
  implementation_revision text;
  accepted_revision text;
  visual_required boolean;
  visual_source text;
BEGIN
  SELECT * INTO item FROM api.work_items WHERE id = target_work_item_id;
  IF item.id IS NULL THEN RAISE EXCEPTION 'Work item not found.'; END IF;
  IF item.kind = 'story' AND item.parent_id IS NOT NULL THEN
    SELECT * INTO parent_item FROM api.work_items WHERE id = item.parent_id AND kind = 'feature';
  END IF;
  visual_required := api.work_item_requires_visual_evidence(item.id);
  visual_source := CASE
    WHEN item.visual_evidence_required THEN item.kind
    WHEN parent_item.visual_evidence_required THEN 'feature'
    ELSE NULL
  END;
  context := api.get_work_item_context(target_work_item_id);
  SELECT COALESCE(jsonb_agg(to_jsonb(asset) ORDER BY asset.is_primary DESC, asset.created_at DESC), '[]'::jsonb)
  INTO assets FROM api.work_item_assets asset WHERE asset.work_item_id = item.id;
  context := context || jsonb_build_object(
    'visual_assets', assets,
    'visual_evidence_required', visual_required,
    'visual_requirement_source', visual_source
  );
  context := jsonb_set(context, '{story,visual_evidence_required}', to_jsonb(visual_required), true);
  IF NOT visual_required THEN RETURN context; END IF;

  current_stage_slug := context #>> '{promotion,current_stage,slug}';
  requirements := COALESCE(context #> '{promotion,acceptance_criteria}', '[]'::jsonb);
  SELECT evidence.revision INTO implementation_revision FROM api.work_item_evidence evidence
  WHERE evidence.work_item_id = item.id AND evidence.evidence_type = 'implementation'
    AND evidence.outcome IN ('recorded','passed') AND evidence.revision IS NOT NULL
  ORDER BY evidence.created_at DESC LIMIT 1;
  IF api.acceptance_criteria_passed_for_one_revision(item.acceptance_criteria) THEN
    SELECT criterion->>'revision' INTO accepted_revision FROM jsonb_array_elements(item.acceptance_criteria) criterion LIMIT 1;
  END IF;

  requirements := requirements || CASE current_stage_slug
    WHEN 'plan' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'A visual mockup or wireframe is attached before implementation begins',
      'satisfied', EXISTS (SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id AND asset.asset_type IN ('mockup','wireframe')),
      'blocking', true
    ))
    WHEN 'build' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'An implementation screenshot is attached for the exact revision being validated',
      'satisfied', implementation_revision IS NOT NULL AND EXISTS (
        SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id
          AND asset.asset_type = 'implementation_screenshot' AND asset.revision = implementation_revision
      ),
      'revision', implementation_revision, 'blocking', true
    ))
    WHEN 'validate' THEN jsonb_build_array(jsonb_build_object(
      'requirement', 'Visual validation or a visual diff is attached for the accepted revision',
      'satisfied', accepted_revision IS NOT NULL AND EXISTS (
        SELECT 1 FROM api.work_item_assets asset WHERE asset.work_item_id = item.id
          AND asset.asset_type IN ('visual_validation','visual_diff') AND asset.revision = accepted_revision
      ),
      'revision', accepted_revision, 'blocking', true
    ))
    ELSE '[]'::jsonb
  END;
  context := jsonb_set(context, '{promotion,acceptance_criteria}', requirements, true);
  context := jsonb_set(context, '{promotion,ready}', to_jsonb(NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(requirements) requirement
    WHERE COALESCE((requirement->>'blocking')::boolean, true)
      AND NOT COALESCE((requirement->>'satisfied')::boolean, false)
  )), true);
  RETURN context;
END $$;

GRANT EXECUTE ON FUNCTION api.work_item_requires_visual_evidence(uuid) TO web_anon;
GRANT EXECUTE ON FUNCTION api.set_visual_evidence_requirement(uuid, boolean, text) TO web_anon;
GRANT EXECUTE ON FUNCTION api.get_work_item_context_with_visuals(uuid) TO web_anon;

NOTIFY pgrst, 'reload schema';
