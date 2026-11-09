UPDATE api.project_artifacts
SET content = CASE artifact_type
  WHEN 'risk_register' THEN E'| ID | Risk | Likelihood | Impact | Mitigation | Owner | Status |\n| --- | --- | --- | --- | --- | --- | --- |'
  WHEN 'issue_register' THEN E'| ID | Issue | Priority | Owner | Status | Resolution |\n| --- | --- | --- | --- | --- | --- |'
  ELSE content
END
WHERE artifact_type IN ('risk_register', 'issue_register')
  AND btrim(content) = '';

NOTIFY pgrst, 'reload schema';
