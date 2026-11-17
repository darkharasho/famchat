import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api } from "./chat-helpers";
import { insertFamily, insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

async function requested(name = "Smiths") {
  const creator = await insertUserWithDevice({ name: "Sam", families: [] });
  const id = await insertFamily({ name, status: "pending", createdBy: creator.userId });
  await env.DB.prepare("INSERT INTO family_members (family_id, user_id, role, joined_at) VALUES (?, ?, 'admin', 1)")
    .bind(id, creator.userId).run();
  return { creator, id };
}

describe("operator family approval", () => {
  it("operator lists pending requests with creator name", async () => {
    const { creator, id } = await requested();
    const op = await insertUserWithDevice({ operator: true });
    await insertFamily({ name: "Done" });
    const res = await api(op.accessToken, "GET", "/operator/families");
    expect(res.status).toBe(200);
    const body = await res.json<{ families: Record<string, unknown>[] }>();
    expect(body.families).toHaveLength(1);
    expect(body.families[0]).toMatchObject({
      id, name: "Smiths", status: "pending", decidedAt: null,
      creator: { id: creator.userId, name: "Sam" }, memberCount: 1,
    });
    expect(typeof body.families[0].createdAt).toBe("number");
    const approved = await (await api(op.accessToken, "GET", "/operator/families?status=approved")).json<{ families: { name: string }[] }>();
    expect(approved.families.map((f) => f.name)).toContain("Done");
    expect((await api(op.accessToken, "GET", "/operator/families?status=bogus")).status).toBe(400);
  });

  it("non-operator gets 403", async () => {
    const { id } = await requested();
    const u = await insertUserWithDevice({});
    expect((await api(u.accessToken, "GET", "/operator/families")).status).toBe(403);
    expect((await api(u.accessToken, "POST", `/operator/families/${id}/approve`)).status).toBe(403);
    expect((await api(u.accessToken, "POST", `/operator/families/${id}/decline`)).status).toBe(403);
  });

  it("approve makes the family approved and the creator gets a family event", async () => {
    const { creator, id } = await requested();
    const op = await insertUserWithDevice({ operator: true });
    const sc = await socket(creator);
    expect((await api(op.accessToken, "POST", `/operator/families/${id}/approve`)).status).toBe(204);
    expect(await sc.next("family")).toEqual({ type: "family", familyId: id });
    const list = await (await api(creator.accessToken, "GET", "/families")).json<{ families: { id: number; status: string }[] }>();
    expect(list.families.find((f) => f.id === id)?.status).toBe("approved");
    const row = await env.DB.prepare("SELECT decided_at, decided_by FROM families WHERE id = ?").bind(id).first<{ decided_at: number; decided_by: string }>();
    expect(row!.decided_by).toBe(op.userId);
    expect(row!.decided_at).toBeGreaterThan(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'family_approved'").first<number>("n")).toBe(1);
  });

  it("decline sets declined and the creator gets a family event", async () => {
    const { creator, id } = await requested();
    const op = await insertUserWithDevice({ operator: true });
    const sc = await socket(creator);
    expect((await api(op.accessToken, "POST", `/operator/families/${id}/decline`)).status).toBe(204);
    expect(await sc.next("family")).toEqual({ type: "family", familyId: id });
    expect(await env.DB.prepare("SELECT status FROM families WHERE id = ?").bind(id).first("status")).toBe("declined");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'family_declined'").first<number>("n")).toBe(1);
  });

  it("approving twice is 409", async () => {
    const { id } = await requested();
    const op = await insertUserWithDevice({ operator: true });
    expect((await api(op.accessToken, "POST", `/operator/families/${id}/approve`)).status).toBe(204);
    expect((await api(op.accessToken, "POST", `/operator/families/${id}/approve`)).status).toBe(409);
    expect((await api(op.accessToken, "POST", `/operator/families/${id}/decline`)).status).toBe(409);
  });

  it("the reviewer family never appears", async () => {
    const op = await insertUserWithDevice({ operator: true });
    await env.DB.prepare("UPDATE families SET status = 'pending' WHERE id = 2").run();
    const list = await (await api(op.accessToken, "GET", "/operator/families")).json<{ families: unknown[] }>();
    expect(list.families).toEqual([]);
    expect((await api(op.accessToken, "POST", "/operator/families/2/approve")).status).toBe(404);
    expect((await api(op.accessToken, "POST", "/operator/families/9999/approve")).status).toBe(404);
  });
});
