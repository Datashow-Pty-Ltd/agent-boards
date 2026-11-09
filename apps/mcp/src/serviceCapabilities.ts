import { readFile } from "node:fs/promises";
import path from "node:path";

export const serviceCapabilityIds = ["repository_intelligence", "visual_implementation", "visual_validation"] as const;
export type ServiceCapabilityId = (typeof serviceCapabilityIds)[number];

export type ServiceCapabilityDescriptor = {
  id: ServiceCapabilityId;
  title: string;
  description: string;
  resourceUri: string;
  instructionsTool: "get_service_capability";
  requiredWhen: string;
  agentResponsibility: string;
  boardResponsibility: string;
  productDesignRoute?: "product-design:image-to-code" | "product-design:design-qa";
};

const descriptors: Record<ServiceCapabilityId, ServiceCapabilityDescriptor & { skillPath: string }> = {
  repository_intelligence: {
    id: "repository_intelligence",
    title: "Repository intelligence",
    description: "Use revision-pinned repository search, symbols, imports, diffs, quality definitions, and cited maps.",
    resourceUri: "agent-boards://skills/repository-intelligence",
    instructionsTool: "get_service_capability",
    requiredWhen: "The Agent Boards project has a linked source repository.",
    agentResponsibility: "Interpret repository facts, perform development, execute checks, and record exact-revision evidence.",
    boardResponsibility: "Index source read-only, preserve provenance, expose query tools, and persist revision-pinned maps.",
    skillPath: "repository-intelligence/SKILL.md",
  },
  visual_implementation: {
    id: "visual_implementation",
    title: "Visual implementation",
    description: "Implement approved visual work in the linked repository and attach exact-revision evidence.",
    resourceUri: "agent-boards://skills/visual-implementation",
    instructionsTool: "get_service_capability",
    requiredWhen: "The work package reports visual_evidence_required=true and the story is being implemented.",
    agentResponsibility: "Use native coding, browser, image, recording, and testing capabilities to perform the work.",
    boardResponsibility: "Supply approved inputs and tools, preserve evidence, and enforce invariants and promotion gates.",
    productDesignRoute: "product-design:image-to-code",
    skillPath: "visual-implementation/SKILL.md",
  },
  visual_validation: {
    id: "visual_validation",
    title: "Visual validation",
    description: "Compare an exact implementation revision with approved mockups and, for interactive work, record a human-readable continuous walkthrough.",
    resourceUri: "agent-boards://skills/visual-validation",
    instructionsTool: "get_service_capability",
    requiredWhen: "The work package reports visual_evidence_required=true and the story is in Validate.",
    agentResponsibility: "Use native browser, DOM, screenshot, image-comparison, recording, and testing capabilities; show visible, deliberate human-like interaction without jump cuts.",
    boardResponsibility: "Supply source assets and evidence tools, verify recording metadata, require human recording approval, derive tolerance results, and enforce the gates.",
    productDesignRoute: "product-design:design-qa",
    skillPath: "visual-validation/SKILL.md",
  },
};

function skillsDirectory() {
  return process.env.SERVICE_SKILLS_DIR ?? path.join(process.cwd(), "skills");
}

export function listServiceCapabilities(): ServiceCapabilityDescriptor[] {
  return serviceCapabilityIds.map(getServiceCapabilityDescriptor);
}

export function getServiceCapabilityDescriptor(id: ServiceCapabilityId): ServiceCapabilityDescriptor {
  const source = descriptors[id];
  return {
    id: source.id,
    title: source.title,
    description: source.description,
    resourceUri: source.resourceUri,
    instructionsTool: source.instructionsTool,
    requiredWhen: source.requiredWhen,
    agentResponsibility: source.agentResponsibility,
    boardResponsibility: source.boardResponsibility,
    ...(source.productDesignRoute ? { productDesignRoute: source.productDesignRoute } : {}),
  };
}

export async function readServiceCapability(id: ServiceCapabilityId) {
  const descriptor = getServiceCapabilityDescriptor(id);
  const instructions = await readFile(path.join(skillsDirectory(), descriptors[id].skillPath), "utf8");
  return { ...descriptor, instructions };
}

export function capabilitiesForWorkPackage(workPackage: Record<string, unknown>, hasRepository = false) {
  const story = typeof workPackage.story === "object" && workPackage.story !== null && !Array.isArray(workPackage.story)
    ? workPackage.story as Record<string, unknown>
    : null;
  const requiresVisualEvidence = workPackage.visual_evidence_required === true || story?.visual_evidence_required === true;
  const isDesignCard = typeof story?.design_card_type === "string" && story.design_card_type.length > 0;
  const capabilities: ServiceCapabilityDescriptor[] = [];
  if (hasRepository) capabilities.push(getServiceCapabilityDescriptor("repository_intelligence"));
  if (requiresVisualEvidence && !isDesignCard) {
    capabilities.push(
      getServiceCapabilityDescriptor("visual_implementation"),
      getServiceCapabilityDescriptor("visual_validation"),
    );
  }
  return capabilities;
}
