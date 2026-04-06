import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Db } from "@paperclipai/db";
import type { PluginEvent } from "@paperclipai/plugin-sdk";

// Mock adjacent services that logActivity calls but are not under test here.
vi.mock("../services/instance-settings.js", () => ({
  instanceSettingsService: () => ({
    getGeneral: vi.fn().mockResolvedValue({ censorUsernameInLogs: false }),
  }),
}));

vi.mock("../services/live-events.js", () => ({
  publishLiveEvent: vi.fn(),
}));

vi.mock("../log-redaction.js", () => ({
  redactCurrentUserValue: (record: unknown) => record,
}));

vi.mock("../redaction.js", () => ({
  sanitizeRecord: (record: unknown) => record,
}));

vi.mock("../middleware/logger.js", () => ({
  logger: { warn: vi.fn(), info: vi.fn(), error: vi.fn() },
}));

// Import *after* mocks so the module picks up mocked deps.
const {
  logActivity,
  setPluginEventBus,
  __clearProjectNameCacheForTests,
} = await import("../services/activity-log.js");

/**
 * Minimal Db stub. `db.insert(activityLog).values(...)` needs to resolve, and
 * `db.select({...}).from(projects).where(...).limit(1)` needs to return a
 * thenable that yields [{name: ...}] | [].
 */
function createDbStub(opts: { projectName?: string | null } = {}): {
  db: Db;
  projectQueryCount: { count: number };
} {
  const projectQueryCount = { count: 0 };
  const db = {
    insert: () => ({
      values: vi.fn().mockResolvedValue(undefined),
    }),
    select: (cols?: Record<string, unknown>) => {
      // select() with no columns is used by instanceSettings; but we've mocked
      // that. Only the projectName lookup hits select here.
      const rows =
        opts.projectName === undefined
          ? [{ name: "Default Project" }]
          : opts.projectName === null
          ? []
          : [{ name: opts.projectName }];
      return {
        from: () => ({
          where: () => ({
            limit: () => {
              projectQueryCount.count += 1;
              return Promise.resolve(rows);
            },
          }),
        }),
      };
    },
  } as unknown as Db;
  return { db, projectQueryCount };
}

function captureEmittedEvents(): {
  events: PluginEvent[];
  waitForEmit: () => Promise<void>;
} {
  const events: PluginEvent[] = [];
  let resolveNext: (() => void) | null = null;
  const bus = {
    emit: vi.fn(async (event: PluginEvent) => {
      events.push(event);
      if (resolveNext) {
        const r = resolveNext;
        resolveNext = null;
        r();
      }
      return { errors: [] };
    }),
    forPlugin: vi.fn(),
    clearPlugin: vi.fn(),
    subscriptionCount: vi.fn(() => 0),
  } as any;
  setPluginEventBus(bus);
  const waitForEmit = () =>
    new Promise<void>((resolve) => {
      if (events.length > 0) {
        resolve();
        return;
      }
      resolveNext = resolve;
    });
  return { events, waitForEmit };
}

describe("logActivity plugin event — project enrichment", () => {
  beforeEach(() => {
    __clearProjectNameCacheForTests();
  });

  it("includes projectId and resolved projectName when projectId is provided", async () => {
    const { db } = createDbStub({ projectName: "Mobile App" });
    const { events, waitForEmit } = captureEmittedEvents();

    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "issue.created",
      entityType: "issue",
      entityId: "issue-1",
      projectId: "proj-123",
      details: { title: "Fix login bug", identifier: "APP-7" },
    });
    await waitForEmit();

    expect(events).toHaveLength(1);
    expect(events[0].eventType).toBe("issue.created");
    expect(events[0].payload).toMatchObject({
      projectId: "proj-123",
      projectName: "Mobile App",
      title: "Fix login bug",
      identifier: "APP-7",
    });
  });

  it("sets projectId and projectName to null when projectId is not provided", async () => {
    const { db } = createDbStub();
    const { events, waitForEmit } = captureEmittedEvents();

    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "issue.created",
      entityType: "issue",
      entityId: "issue-1",
      details: { title: "No project", identifier: "X-1" },
    });
    await waitForEmit();

    expect(events).toHaveLength(1);
    expect(events[0].payload).toMatchObject({
      projectId: null,
      projectName: null,
    });
  });

  it("caches project-name lookups and does not re-query for repeated projectIds", async () => {
    const { db, projectQueryCount } = createDbStub({ projectName: "Cached" });
    const { events, waitForEmit } = captureEmittedEvents();

    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "issue.created",
      entityType: "issue",
      entityId: "issue-1",
      projectId: "proj-cache",
      details: { title: "one" },
    });
    await waitForEmit();

    // second call — should hit cache
    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "issue.updated",
      entityType: "issue",
      entityId: "issue-1",
      projectId: "proj-cache",
      details: { status: "done" },
    });
    // wait for second event
    await new Promise<void>((resolve) => {
      const tick = () => (events.length >= 2 ? resolve() : setTimeout(tick, 1));
      tick();
    });

    expect(events).toHaveLength(2);
    expect(projectQueryCount.count).toBe(1);
    expect(events[0].payload).toMatchObject({ projectName: "Cached" });
    expect(events[1].payload).toMatchObject({ projectName: "Cached" });
  });

  it("sets projectName to null when the project row is not found", async () => {
    const { db } = createDbStub({ projectName: null });
    const { events, waitForEmit } = captureEmittedEvents();

    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "issue.created",
      entityType: "issue",
      entityId: "issue-1",
      projectId: "proj-missing",
      details: { title: "missing project" },
    });
    await waitForEmit();

    expect(events[0].payload).toMatchObject({
      projectId: "proj-missing",
      projectName: null,
    });
  });

  it("does not emit a plugin event for actions outside PLUGIN_EVENT_TYPES", async () => {
    const { db } = createDbStub({ projectName: "X" });
    const { events } = captureEmittedEvents();

    await logActivity(db, {
      companyId: "company-1",
      actorType: "user",
      actorId: "user-1",
      action: "some.non.plugin.action",
      entityType: "issue",
      entityId: "issue-1",
      projectId: "proj-123",
      details: { title: "test" },
    });
    // small delay to let any microtasks settle
    await new Promise((r) => setTimeout(r, 5));

    expect(events).toHaveLength(0);
  });
});
