CREATE OR REPLACE FUNCTION api.enforce_work_item_stage_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  previous_stage api.board_stages;
  next_stage api.board_stages;
BEGIN
  IF NEW.stage_id = OLD.stage_id THEN RETURN NEW; END IF;
  SELECT * INTO previous_stage FROM api.board_stages WHERE id = OLD.stage_id;
  SELECT * INTO next_stage FROM api.board_stages WHERE id = NEW.stage_id;
  IF next_stage.id IS NULL OR next_stage.board_id <> OLD.board_id THEN
    RAISE EXCEPTION 'Target stage does not belong to this board.' USING ERRCODE = '23514';
  END IF;
  IF NOT (previous_stage.allowed_transitions ? next_stage.slug) THEN
    RAISE EXCEPTION 'Cannot move from % to %. Allowed next stages: %',
      previous_stage.title,
      next_stage.title,
      COALESCE((SELECT string_agg(value, ', ') FROM jsonb_array_elements_text(previous_stage.allowed_transitions)), 'none')
      USING ERRCODE = '23514',
            HINT = 'Move the card through each governed stage; completed work in Done is terminal.';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_work_item_stage_transition ON api.work_items;
CREATE TRIGGER enforce_work_item_stage_transition
  BEFORE UPDATE OF stage_id ON api.work_items
  FOR EACH ROW EXECUTE FUNCTION api.enforce_work_item_stage_transition();

NOTIFY pgrst, 'reload schema';
