import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { Db } from "@paperclipai/db";
import { activityLog, projects } from "@paperclipai/db";
import { PLUGIN_EVENT_TYPES, type PluginEventType } from "@paperclipai/shared";
import type { PluginEvent } from "@paperclipai/plugin-sdk";
import { publishLiveEvent } from "./live-events.js";
import { redactCurrentUserValue } from "../log-redaction.js";
import { sanitizeRecord } from "../redaction.js";
import { logger } from "../middleware/logger.js";
import type { PluginEventBus } from "./plugin-event-bus.js";
import { instanceSettingsService } from "./instance-settings.js";

const PLUGIN_EVENT_SET: ReadonlySet<string> = new Set(PLUGIN_EVENT_TYPES);

let _pluginEventBus: PluginEventBus | null = null;

// Project-name cache for plugin event enrichment.
// Keyed by projectId. Cached names are attached to plugin event payloads so
// consumers (e.g. the Telegram plugin's forum-topic routing) can route by name
// without re-querying on every event. Project renames are rare, so a generous
// TTL is fine; we clear on miss so deleted projects don't persist.
const PROJECT_NAME_TTL_MS = 5 * 60 * 1000;
const _projectNameCache = new Map<string, { name: string | null; expiresAt: number }>();

async function resolveProjectNameForEvent(
  db: Db,
  projectId: string,
): Promise<string | null> {
  const now = Date.now();
  const cached = _projectNameCache.get(projectId);
  if (cached && cached.expiresAt > now) {
    return cached.name;
  }
  try {
    const row = await db
      .select({ name: projects.name })
      .from(projects)
      .where(eq(projects.id, projectId))
      .limit(1)
      .then((rows) => rows[0] ?? null);
    const name = row?.name ?? null;
    _projectNameCache.set(projectId, { name, expiresAt: now + PROJECT_NAME_TTL_MS });
    return name;
  } catch (err) {
    logger.warn({ projectId, err }, "failed to resolve project name for plugin event");
    return null;
  }
}

/**
 * Test-only: clear the project-name cache between tests.
 * @internal
 */
export function __clearProjectNameCacheForTests(): void {
  _projectNameCache.clear();
}

/** Wire the plugin event bus so domain events are forwarded to plugins. */
export function setPluginEventBus(bus: PluginEventBus): void {
  if (_pluginEventBus) {
    logger.warn("setPluginEventBus called more than once, replacing existing bus");
  }
  _pluginEventBus = bus;
}

export interface LogActivityInput {
  companyId: string;
  actorType: "agent" | "user" | "system";
  actorId: string;
  action: string;
  entityType: string;
  entityId: string;
  agentId?: string | null;
  runId?: string | null;
  /**
   * Optional project context. When set and the `action` is a plugin event type,
   * both `projectId` and the resolved `projectName` are added to the plugin
   * event payload — enabling project-aware routing in plugins (e.g. Telegram
   * forum-topic mapping). Not persisted to the activity log DB row.
   */
  projectId?: string | null;
  details?: Record<string, unknown> | null;
}

export async function logActivity(db: Db, input: LogActivityInput) {
  const currentUserRedactionOptions = {
    enabled: (await instanceSettingsService(db).getGeneral()).censorUsernameInLogs,
  };
  const sanitizedDetails = input.details ? sanitizeRecord(input.details) : null;
  const redactedDetails = sanitizedDetails
    ? redactCurrentUserValue(sanitizedDetails, currentUserRedactionOptions)
    : null;
  await db.insert(activityLog).values({
    companyId: input.companyId,
    actorType: input.actorType,
    actorId: input.actorId,
    action: input.action,
    entityType: input.entityType,
    entityId: input.entityId,
    agentId: input.agentId ?? null,
    runId: input.runId ?? null,
    details: redactedDetails,
  });

  publishLiveEvent({
    companyId: input.companyId,
    type: "activity.logged",
    payload: {
      actorType: input.actorType,
      actorId: input.actorId,
      action: input.action,
      entityType: input.entityType,
      entityId: input.entityId,
      agentId: input.agentId ?? null,
      runId: input.runId ?? null,
      details: redactedDetails,
    },
  });

  if (_pluginEventBus && PLUGIN_EVENT_SET.has(input.action)) {
    const projectId = input.projectId ?? null;
    const projectName = projectId ? await resolveProjectNameForEvent(db, projectId) : null;
    const event: PluginEvent = {
      eventId: randomUUID(),
      eventType: input.action as PluginEventType,
      occurredAt: new Date().toISOString(),
      actorId: input.actorId,
      actorType: input.actorType,
      entityId: input.entityId,
      entityType: input.entityType,
      companyId: input.companyId,
      payload: {
        ...redactedDetails,
        agentId: input.agentId ?? null,
        runId: input.runId ?? null,
        projectId,
        projectName,
      },
    };
    void _pluginEventBus.emit(event).then(({ errors }) => {
      for (const { pluginId, error } of errors) {
        logger.warn({ pluginId, eventType: event.eventType, err: error }, "plugin event handler failed");
      }
    }).catch(() => {});
  }
}
