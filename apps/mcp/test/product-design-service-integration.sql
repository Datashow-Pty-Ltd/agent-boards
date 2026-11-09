-- Run against a populated Agent Boards database. The assertion discovers one
-- governed visual story, deliberately records a divergent critique, proves the
-- promotion gate remains closed, and rolls back every change.
BEGIN;

DO $assertion$
DECLARE
  item api.work_items;
  source_asset api.work_item_assets;
  implementation_asset api.work_item_assets;
  validation_asset api.work_item_assets;
  implementation_package jsonb;
  critique_package jsonb;
  result jsonb;
BEGIN
  SELECT story.* INTO item
  FROM api.work_items story
  WHERE story.kind = 'story'
    AND api.work_item_requires_visual_evidence(story.id)
    AND EXISTS (
      SELECT 1
      FROM api.work_item_assets source
      JOIN api.work_items owner_item ON owner_item.id = source.work_item_id
      WHERE source.project_id = story.project_id
        AND source.asset_type IN ('mockup', 'wireframe')
        AND source.approval_status = 'approved'
        AND source.viewport_width IS NOT NULL
        AND source.viewport_height IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(story.screen_names) screen
          WHERE lower(screen) = lower(source.screen_name)
        )
        AND (owner_item.id = story.id OR owner_item.design_card_type = 'screen_mockup')
        AND EXISTS (
          SELECT 1
          FROM api.work_item_assets rendered
          JOIN api.work_item_assets comparison
            ON comparison.work_item_id = rendered.work_item_id
            AND comparison.revision = rendered.revision
            AND comparison.viewport_width = rendered.viewport_width
            AND comparison.viewport_height = rendered.viewport_height
            AND comparison.asset_type IN ('visual_validation', 'visual_diff')
          WHERE rendered.work_item_id = story.id
            AND rendered.asset_type = 'implementation_screenshot'
            AND rendered.viewport_width = source.viewport_width
            AND rendered.viewport_height = source.viewport_height
        )
    )
  ORDER BY story.updated_at DESC
  LIMIT 1;

  IF item.id IS NULL THEN
    RAISE EXCEPTION 'The integration assertion requires one governed visual story with approved, rendered, and comparison assets.';
  END IF;

  SELECT source.* INTO source_asset
  FROM api.work_item_assets source
  JOIN api.work_items owner_item ON owner_item.id = source.work_item_id
  WHERE source.project_id = item.project_id
    AND source.asset_type IN ('mockup', 'wireframe')
    AND source.approval_status = 'approved'
    AND source.viewport_width IS NOT NULL
    AND source.viewport_height IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(item.screen_names) screen
      WHERE lower(screen) = lower(source.screen_name)
    )
    AND (owner_item.id = item.id OR owner_item.design_card_type = 'screen_mockup')
  ORDER BY source.approved_at DESC NULLS LAST, source.created_at DESC
  LIMIT 1;

  SELECT rendered.* INTO implementation_asset
  FROM api.work_item_assets rendered
  WHERE rendered.work_item_id = item.id
    AND rendered.asset_type = 'implementation_screenshot'
    AND rendered.viewport_width = source_asset.viewport_width
    AND rendered.viewport_height = source_asset.viewport_height
    AND EXISTS (
      SELECT 1 FROM api.work_item_assets comparison
      WHERE comparison.work_item_id = rendered.work_item_id
        AND comparison.revision = rendered.revision
        AND comparison.viewport_width = rendered.viewport_width
        AND comparison.viewport_height = rendered.viewport_height
        AND comparison.asset_type IN ('visual_validation', 'visual_diff')
    )
  ORDER BY rendered.created_at DESC
  LIMIT 1;

  SELECT comparison.* INTO validation_asset
  FROM api.work_item_assets comparison
  WHERE comparison.work_item_id = item.id
    AND comparison.asset_type IN ('visual_validation', 'visual_diff')
    AND comparison.revision = implementation_asset.revision
    AND comparison.viewport_width = implementation_asset.viewport_width
    AND comparison.viewport_height = implementation_asset.viewport_height
  ORDER BY comparison.created_at DESC
  LIMIT 1;

  implementation_package := api.get_mockup_implementation_package(item.id);
  IF implementation_package #>> '{workflow,product_design_route}' <> 'product-design:image-to-code'
    OR jsonb_array_length(implementation_package->'approved_static_mockups') = 0 THEN
    RAISE EXCEPTION 'The implementation package did not resolve its Product Design route and approved source.';
  END IF;

  critique_package := api.get_visual_critique_package(
    item.id, source_asset.screen_name, implementation_asset.revision
  );
  IF critique_package #>> '{workflow,product_design_route}' <> 'product-design:design-qa'
    OR NOT COALESCE((critique_package->>'same_viewport')::boolean, false) THEN
    RAISE EXCEPTION 'The critique package did not bind equal-viewport source and rendered assets.';
  END IF;

  result := api.record_visual_critique(
    target_work_item_id := item.id,
    target_screen_name := source_asset.screen_name,
    target_source_mockup_asset_id := source_asset.id,
    target_validation_asset_id := validation_asset.id,
    target_revision := implementation_asset.revision,
    target_viewport_width := source_asset.viewport_width,
    target_viewport_height := source_asset.viewport_height,
    target_comparison_method := 'side_by_side',
    target_same_viewport := true,
    target_structural_match := true,
    target_controls_present := false,
    target_measurements := $measurements$[
      {"surface":"typography","element":"title","property":"font-family","referenceValue":"Approved","implementationValue":"Approved","unit":"font","tolerance":0,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"typography","element":"title","property":"font-size","referenceValue":40,"implementationValue":40,"unit":"px","tolerance":1,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"typography","element":"title","property":"font-weight","referenceValue":900,"implementationValue":900,"unit":"weight","tolerance":0,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"typography","element":"title","property":"line-height","referenceValue":44,"implementationValue":44,"unit":"px","tolerance":1,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"typography","element":"title","property":"letter-spacing","referenceValue":1,"implementationValue":1,"unit":"px","tolerance":0.25,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"geometry","element":"major surface","property":"x","referenceValue":24,"implementationValue":24,"unit":"px","tolerance":2,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"geometry","element":"major surface","property":"y","referenceValue":180,"implementationValue":180,"unit":"px","tolerance":2,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"geometry","element":"major surface","property":"width","referenceValue":342,"implementationValue":362,"unit":"px","tolerance":2,"delta":20,"severity":"P1","method":"fixture"},
      {"surface":"geometry","element":"major surface","property":"height","referenceValue":236,"implementationValue":236,"unit":"px","tolerance":2,"delta":0,"severity":"P1","method":"fixture"},
      {"surface":"geometry","element":"major surface","property":"border-radius","referenceValue":24,"implementationValue":24,"unit":"px","tolerance":1,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"spacing","element":"page","property":"page-inset","referenceValue":24,"implementationValue":24,"unit":"px","tolerance":2,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"spacing","element":"sections","property":"section-gap","referenceValue":20,"implementationValue":20,"unit":"px","tolerance":2,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"spacing","element":"components","property":"component-gap","referenceValue":12,"implementationValue":12,"unit":"px","tolerance":1,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"color","element":"foreground","property":"color","referenceValue":"#392719","implementationValue":"#392719","unit":"hex","tolerance":0,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"color","element":"page","property":"background-color","referenceValue":"#f8f1df","implementationValue":"#f8f1df","unit":"hex","tolerance":0,"delta":0,"severity":"P2","method":"fixture"},
      {"surface":"color","element":"surface","property":"border-color","referenceValue":"#d8c196","implementationValue":"#d8c196","unit":"hex","tolerance":0,"delta":0,"severity":"P2","method":"fixture"}
    ]$measurements$::jsonb,
    target_findings := '[{"severity":"P1","summary":"Deliberate 20px width divergence.","resolved":false,"element":"major surface","property":"width"}]'::jsonb,
    target_measurement_method := 'Deterministic transactional integration fixture.',
    critique_notes := 'Expected failure; rolled back after assertion.',
    actor_name := 'Product Design service integration test'
  );

  IF COALESCE((result->>'passed')::boolean, true)
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(result->'promotion_gate') requirement
      WHERE NOT COALESCE((requirement->>'satisfied')::boolean, true)
        AND COALESCE((requirement->>'unresolved_p1')::integer, 0) > 0
    ) THEN
    RAISE EXCEPTION 'A deliberately divergent implementation incorrectly satisfied visual promotion.';
  END IF;

  RAISE NOTICE 'PASS: % source and rendered assets resolved; divergent critique remained blocked.', item.item_key;
END $assertion$;

ROLLBACK;
