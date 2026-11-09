import assert from "node:assert/strict";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const gatewayUrl = process.env.AGENT_BOARDS_URL ?? "http://127.0.0.1:4173";

async function api(path, init = {}) {
  const response = await fetch(`${gatewayUrl}/api${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", Prefer: "return=representation", ...init.headers },
  });
  if (!response.ok) assert.fail(`${init.method ?? "GET"} ${path} failed: ${response.status} ${await response.text()}`);
  return response.status === 204 ? null : response.json();
}

async function apiFailure(path, init = {}) {
  const response = await fetch(`${gatewayUrl}/api${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", Prefer: "return=representation", ...init.headers },
  });
  assert.ok(!response.ok, `${init.method ?? "GET"} ${path} should have been rejected`);
  return response.text();
}

function resultJson(result) {
  const text = result.content?.find((entry) => entry.type === "text")?.text;
  assert.ok(text, "MCP result should contain JSON text");
  return JSON.parse(text);
}

test("registered Codex and Claude workers claim and move distinct stories concurrently", async () => {
  const suffix = `${Date.now()}`.slice(-8);
  const projectKey = `MW${suffix}`;
  const [project] = await api("/rpc/create_project", {
    method: "POST",
    body: JSON.stringify({
      project_name: "Multi-worker smoke test",
      project_key: projectKey,
      project_description: "Disposable concurrent MCP claim test.",
      project_owner: "Release test",
    }),
  });
  const workerSpecs = [
    { handle: `codex-alpha-${suffix}`, displayName: "Codex Alpha", clientType: "codex", capabilities: ["image_generation"] },
    { handle: `claude-beta-${suffix}`, displayName: "Claude Beta", clientType: "claude", capabilities: ["browser_automation"] },
    { handle: `codex-gamma-${suffix}`, displayName: "Codex Gamma", clientType: "codex", capabilities: [] },
    { handle: `codex-delta-${suffix}`, displayName: "Codex Delta", clientType: "codex", capabilities: ["image_generation"] },
  ];
  const clients = [];
  const identities = [];
  const createdStories = [];

  try {
    const [board] = await api(`/boards?project_id=eq.${project.id}&select=id`);
    for (let index = 0; index < 3; index += 1) {
      const [createdStory] = await api("/rpc/create_backlog_item", {
        method: "POST",
        body: JSON.stringify({
          target_project_id: project.id,
          item_title: `Concurrent story ${index + 1}`,
          item_description: "A ready story used to prove parallel claims.",
          item_kind: "story",
          item_priority: "high",
          parent_work_item_id: null,
          item_assignee: null,
          item_acceptance_criteria: [{
            statement: "The story is claimed by exactly one worker.",
            verification_method: "database_assertion",
            verification_ref: "api.work_items.assignee",
            expected_result: "Three concurrent claims have three distinct work item IDs.",
          }],
          item_invariants: ["A work item has at most one active worker."],
          actor_name: "Release test",
        }),
      });
      createdStories.push(createdStory);
    }
    await api("/rpc/set_work_item_required_capabilities", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: createdStories[0].id, requested_capabilities: ["image_generation"], actor_name: "Release test" }),
    });
    await api("/rpc/set_work_item_required_capabilities", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: createdStories[1].id, requested_capabilities: ["browser_automation"], actor_name: "Release test" }),
    });

    for (const worker of workerSpecs) {
      const client = new Client({ name: worker.displayName, version: "1.0.0" });
      await client.connect(new StreamableHTTPClientTransport(new URL(`${gatewayUrl}/mcp`)));
      clients.push(client);
      identities.push(resultJson(await client.callTool({
        name: "register_worker",
        arguments: { projectId: project.id, ...worker },
      })));
    }

    assert.equal(new Set(identities.map((identity) => identity.worker_id)).size, 4, "worker IDs must be immutable and distinct");
    assert.ok(identities.every((identity) => identity.resume_token?.length >= 32), "registration must return a one-time private token");
    assert.deepEqual(identities[0].capabilities, ["image_generation"]);
    assert.deepEqual(identities[1].capabilities, ["browser_automation"]);
    const resumed = resultJson(await clients[1].callTool({
      name: "resume_worker",
      arguments: { workerId: identities[1].worker_id, resumeToken: identities[1].resume_token },
    }));
    assert.equal(resumed.handle, workerSpecs[1].handle, "Claude should resume its registered identity");
    assert.match(await apiFailure("/rpc/register_agent_worker", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: project.id,
        requested_handle: workerSpecs[0].handle,
        requested_display_name: "Impostor",
        requested_client_type: "other",
      }),
    }), /already registered/i, "a project handle cannot be registered twice");
    assert.match(await apiFailure("/rpc/claim_next_work_package", {
      method: "POST",
      body: JSON.stringify({ target_project_id: project.id, agent_name: "Unregistered Worker" }),
    }), /permission denied/i, "free-form worker names must not bypass registration");

    const claims = await Promise.all(clients.slice(0, 3).map((client, index) => client.callTool({
      name: "claim_next_ready_work_item",
      arguments: {
        projectId: project.id,
        workerId: identities[index].worker_id,
        resumeToken: identities[index].resume_token,
      },
    })));
    const packages = claims.map(resultJson);
    const stories = packages.map((payload) => payload.work_package.story);

    assert.equal(new Set(stories.map((story) => story.id)).size, 3, "every worker should receive a different story");
    stories.forEach((story, index) => {
      assert.equal(story.owner, workerSpecs[index].handle, "first claim should assign durable ownership to the registered handle");
      assert.equal(story.assignee, workerSpecs[index].handle, "claim should record the registered active worker");
      assert.equal(story.assignee_worker_id, identities[index].worker_id, "claim must bind the immutable worker ID");
      const required = packages[index].work_package.required_worker_capabilities;
      assert.ok(required.every((capability) => identities[index].capabilities.includes(capability)), "the queue must only return work compatible with the worker");
    });
    assert.equal(stories[0].id, createdStories[0].id, "the image-capable Codex worker should receive image-generation work");
    assert.equal(stories[1].id, createdStories[1].id, "Claude should receive browser work without claiming image generation");

    await Promise.all(clients.slice(0, 3).map((client, index) => client.callTool({
      name: "move_work_item",
      arguments: {
        workItemId: stories[index].id,
        stage: "analyse",
        workerId: identities[index].worker_id,
        resumeToken: identities[index].resume_token,
      },
    })));

    const moved = await api(`/work_items?project_id=eq.${project.id}&kind=eq.story&select=id,owner,assignee,stage_id`);
    const stages = await api(`/board_stages?board_id=eq.${board.id}&slug=eq.analyse&select=id`);
    assert.equal(moved.length, 3);
    assert.ok(moved.every((story) => story.stage_id === stages[0].id), "all three cards should move independently to Analyse");

    const heartbeat = resultJson(await clients[0].callTool({
      name: "heartbeat_work_item",
      arguments: { workItemId: stories[0].id, workerId: identities[0].worker_id, resumeToken: identities[0].resume_token },
    }));
    assert.equal(heartbeat[0].assignee, workerSpecs[0].handle, "the active worker should renew its own claim");
    assert.match(await apiFailure("/rpc/heartbeat_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: stories[0].id,
        target_worker_id: identities[0].worker_id,
        resume_token: "0".repeat(64),
      }),
    }), /credentials are invalid/i, "an incorrect token must not impersonate a registered worker");

    const activeStatus = resultJson(await clients[0].callTool({
      name: "get_work_item_claim_status",
      arguments: { workItemId: stories[0].id },
    }));
    assert.equal(activeStatus[0].takeover_eligible, false, "a fresh claim cannot be taken over");
    assert.match(await apiFailure("/rpc/authorize_idle_claim_takeover", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: stories[0].id, new_worker_id: identities[3].worker_id, human_name: "Release test" }),
    }), /still active/i);

    const [screenRecordingStory] = await api("/rpc/create_backlog_item", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: project.id,
        item_title: "Capture validation walkthrough",
        item_description: "Capability-routing proof that initially has no compatible worker.",
        item_kind: "story",
        item_priority: "urgent",
        parent_work_item_id: null,
        item_assignee: null,
        item_acceptance_criteria: [{
          statement: "A registered worker captures the validation walkthrough.",
          verification_method: "database_assertion",
          verification_ref: "api.work_items.assignee_worker_id",
          expected_result: "The story is assigned only after screen_recording is registered.",
        }],
        item_invariants: ["Only a screen-recording-capable worker may claim this story."],
        actor_name: "Release test",
      }),
    });
    await api("/rpc/set_work_item_required_capabilities", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: screenRecordingStory.id,
        requested_capabilities: ["screen_recording"],
        actor_name: "Release test",
      }),
    });
    const incompatible = resultJson(await clients[3].callTool({
      name: "claim_next_ready_work_item",
      arguments: {
        projectId: project.id,
        workerId: identities[3].worker_id,
        resumeToken: identities[3].resume_token,
      },
    }));
    assert.equal(incompatible.outcome, "no_compatible_work");
    assert.equal(incompatible.incompatible_work[0].work_item_id, screenRecordingStory.id);

    const updatedWorker = resultJson(await clients[3].callTool({
      name: "update_worker_capabilities",
      arguments: {
        workerId: identities[3].worker_id,
        resumeToken: identities[3].resume_token,
        capabilities: ["image_generation", "screen_recording"],
      },
    }));
    assert.deepEqual(updatedWorker.capabilities, ["image_generation", "screen_recording"]);
    const screenRecordingClaim = resultJson(await clients[3].callTool({
      name: "claim_next_ready_work_item",
      arguments: {
        projectId: project.id,
        workerId: identities[3].worker_id,
        resumeToken: identities[3].resume_token,
      },
    }));
    assert.equal(screenRecordingClaim.work_package.story.id, screenRecordingStory.id);
    assert.match(await apiFailure("/rpc/update_agent_worker_capabilities", {
      method: "POST",
      body: JSON.stringify({
        target_worker_id: identities[3].worker_id,
        resume_token: identities[3].resume_token,
        requested_capabilities: ["image_generation"],
      }),
    }), /active claim.*cannot be removed/i);
    await clients[3].callTool({
      name: "release_work_item",
      arguments: {
        workItemId: screenRecordingStory.id,
        workerId: identities[3].worker_id,
        resumeToken: identities[3].resume_token,
      },
    });

    const staleTimestamp = new Date(Date.now() - 20 * 60_000).toISOString();
    await api(`/work_items?id=eq.${stories[0].id}`, {
      method: "PATCH",
      body: JSON.stringify({ claim_heartbeat_at: staleTimestamp }),
    });
    assert.match(await apiFailure("/rpc/authorize_idle_claim_takeover", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: stories[0].id, new_worker_id: identities[1].worker_id, human_name: "Release test" }),
    }), /does not provide every required capability/i);
    const [takenOver] = await api("/rpc/authorize_idle_claim_takeover", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: stories[0].id, new_worker_id: identities[3].worker_id, human_name: "Release test" }),
    });
    assert.equal(takenOver.owner, workerSpecs[3].handle, "human takeover should transfer durable ownership");
    assert.equal(takenOver.assignee, workerSpecs[3].handle, "human takeover should transfer the active claim");
    assert.equal(takenOver.assignee_worker_id, identities[3].worker_id, "takeover must bind the new immutable worker ID");
    assert.match(await apiFailure("/rpc/move_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: stories[0].id,
        target_stage_slug: "plan",
        target_worker_id: identities[0].worker_id,
        resume_token: identities[0].resume_token,
      }),
    }), /different registered worker/i, "the disconnected worker must be fenced after transfer");

    await api(`/work_items?id=eq.${stories[1].id}`, {
      method: "PATCH",
      body: JSON.stringify({ claim_heartbeat_at: staleTimestamp }),
    });
    const [released] = await api("/rpc/authorize_idle_claim_release", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: stories[1].id, human_name: "Release test" }),
    });
    assert.equal(released.execution_state, "queued", "human release should return stale work to the queue");
    assert.equal(released.assignee, null, "released work should not retain a worker");
    assert.equal(released.owner, workerSpecs[1].handle, "releasing a claim should preserve durable ownership");
    assert.equal(released.assignee_worker_id, null, "released work should clear the immutable worker claim");
  } finally {
    await Promise.allSettled(clients.map((client) => client.close()));
    await api(`/projects?id=eq.${project.id}`, { method: "DELETE" });
  }
});
