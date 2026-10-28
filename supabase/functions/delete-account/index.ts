// Auris: carries out an approved request to delete an account.
//
// The app cannot delete a login itself; that needs the service role key,
// which must never be in the app. A super admin's app calls this function
// with the request's id. The function checks, with the caller's own session,
// that the caller is a super admin and that the request is a pending
// deletion of someone else's (non super admin) account, then deletes the
// login. The profile goes with it; patients and tests stay with the clinic,
// and the request is kept, marked completed.
//
// Deploy: Supabase dashboard -> Edge Functions -> Deploy a new function ->
// Via Editor, name it `delete-account`, paste this file, Deploy. Leave
// "Enforce JWT verification" on.

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return reply(500, { error: "The function is missing its Supabase settings." });
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Who is calling?
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: callerData, error: callerError } = await admin.auth.getUser(token);
  const caller = callerData?.user;
  if (callerError || !caller) return reply(401, { error: "Sign in again." });

  const { data: me } = await admin
    .from("profiles").select("role").eq("id", caller.id).maybeSingle();
  if (me?.role !== "super_admin") {
    return reply(403, { error: "Only a super admin can delete accounts." });
  }

  let requestId: unknown;
  try {
    ({ requestId } = await req.json());
  } catch {
    return reply(400, { error: "Send the request id." });
  }
  if (typeof requestId !== "string") {
    return reply(400, { error: "Send the request id." });
  }

  const { data: request } = await admin
    .from("change_requests").select("*").eq("id", requestId).maybeSingle();
  if (!request || request.kind !== "delete" || request.status !== "pending") {
    return reply(400, { error: "That is not an open request to delete an account." });
  }
  if (!request.user_id) {
    return reply(400, { error: "That account no longer exists." });
  }
  if (request.user_id === caller.id) {
    return reply(400, { error: "You cannot delete your own account here." });
  }
  const { data: target } = await admin
    .from("profiles").select("role").eq("id", request.user_id).maybeSingle();
  if (target?.role === "super_admin") {
    return reply(400, {
      error: "A super admin is removed in the Supabase dashboard, not here.",
    });
  }

  // The account's other open requests (a profile change, a move) end with it.
  // Their ids are read now, because deleting the login clears user_id.
  const { data: others } = await admin
    .from("change_requests").select("id")
    .eq("user_id", request.user_id).eq("status", "pending").neq("id", requestId);
  const otherIds = (others ?? []).map((o: { id: string }) => o.id);

  // Mark the decision first, so the record says who approved it even though
  // the account itself is about to disappear.
  const decidedAt = new Date().toISOString();
  const { error: markError } = await admin.from("change_requests").update({
    status: "completed",
    reviewed_by: caller.id,
    reviewed_at: decidedAt,
  }).eq("id", requestId).eq("status", "pending");
  if (markError) return reply(500, { error: markError.message });

  const { error: deleteError } = await admin.auth.admin.deleteUser(request.user_id);
  if (deleteError) {
    // Put the request back so it can be tried again.
    await admin.from("change_requests").update({
      status: "pending",
      reviewed_by: null,
      reviewed_at: null,
    }).eq("id", requestId);
    return reply(500, { error: deleteError.message });
  }

  if (otherIds.length > 0) {
    await admin.from("change_requests")
      .update({ status: "cancelled" }).in("id", otherIds).eq("status", "pending");
  }

  return reply(200, { deleted: true });
});
