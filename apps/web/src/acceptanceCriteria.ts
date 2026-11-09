import type { AcceptanceCriterionInput, AcceptanceVerificationMethod } from "./types";

export const acceptanceVerificationMethods: Array<{ value: AcceptanceVerificationMethod; label: string }> = [
  { value: "automated_test", label: "Automated test" },
  { value: "command", label: "Command" },
  { value: "http_assertion", label: "HTTP assertion" },
  { value: "database_assertion", label: "Database assertion" },
  { value: "visual_baseline", label: "Visual baseline" },
];

export function emptyAcceptanceCriterion(): AcceptanceCriterionInput {
  return { statement: "", verificationMethod: "automated_test", verificationRef: "", expectedResult: "" };
}
