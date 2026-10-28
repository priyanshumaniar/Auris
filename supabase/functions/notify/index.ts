// Auris: email alerts about approvals.
//
// Called by a Supabase Database Webhook on the change_requests table (insert
// and update). It emails:
//   * the people who can decide a new request (the clinic's admins for staff
//     requests, super admins for the rest, or when a clinic has no admin);
//   * the person who asked, when their request is approved or rejected;
//   * super admins, when a login email changed without approval.
// Anyone who has switched email alerts off in Auris is skipped.
//
// Mail goes through Gmail on port 465. Supabase Edge Functions cannot open
// ports 25 or 587, so 465 is the one to use here (the Auth email settings in
// the dashboard are separate and can stay on 587).
//
// Secrets (Edge Functions -> Secrets):
//   SMTP_USER       the Gmail address that sends the alerts
//   SMTP_PASS       its 16-character app password
//   WEBHOOK_SECRET  any long random text; the webhook sends it in the
//                   x-auris-secret header, so nobody else can trigger emails
//
// Deploy via the dashboard editor as `notify`, and turn OFF "Enforce JWT
// verification" for it: the webhook proves itself with WEBHOOK_SECRET instead.

import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

type Row = Record<string, any>;

const KIND: Record<string, string> = {
  profile: "profile change",
  email: "email change",
  join: "request to join a clinic",
  move: "request to move clinic",
  clinic: "clinic details change",
  delete: "account deletion",
  leave: "clinic leaving",
};

const FIELD: Record<string, string> = {
  display_name: "Name",
  phone: "Phone",
  qualification: "Qualification",
  registration_no: "Registration no.",
  email: "Email",
  name: "Clinic name",
  address: "Address",
  clinic_name: "Clinic",
};

function changes(r: Row): string {
  const payload: Row = r.payload ?? {};
  const previous: Row = r.previous ?? {};
  const lines: string[] = [];
  for (const key of Object.keys(FIELD)) {
    if (!(key in payload)) continue;
    const before = previous[key] ?? "(none)";
    const after = payload[key] ?? "(none)";
    if (before === after) continue;
    lines.push(`  ${FIELD[key]}: ${before} -> ${after}`);
  }
  return lines.join("\n");
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-auris-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const smtpUser = Deno.env.get("SMTP_USER");
  const smtpPass = Deno.env.get("SMTP_PASS");
  if (!smtpUser || !smtpPass) return new Response("no smtp", { status: 500 });

  const db = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const event: Row = await req.json();
  const r: Row | null = event.record;
  const old: Row | null = event.old_record;
  if (!r || event.table !== "change_requests") return new Response("ignored");

  const clinicName = async (id: string | null): Promise<string> => {
    if (!id) return "no clinic";
    const { data } = await db.from("clinics").select("name").eq("id", id).maybeSingle();
    return data?.name ?? "a clinic";
  };
  const alertable = (rows: Row[] | null) =>
    (rows ?? []).filter((p) => p.email && p.email_alerts !== false);
  const superAdmins = async () => {
    const { data } = await db.from("profiles")
      .select("id, email, email_alerts").eq("role", "super_admin");
    return alertable(data);
  };

  const messages: { to: string; subject: string; text: string }[] = [];
  const who = r.user_name || r.user_email || "Someone";
  const label = KIND[r.kind] ?? r.kind;

  if (event.type === "INSERT" && r.status === "pending") {
    // Tell whoever can decide it.
    let reviewers: Row[] = [];
    if (r.reviewer_level === "clinic_admin" && r.clinic_id) {
      const { data } = await db.from("profiles")
        .select("id, email, email_alerts")
        .eq("clinic_id", r.clinic_id).in("role", ["admin", "super_admin"]);
      reviewers = alertable(data);
    }
    if (reviewers.length === 0) reviewers = await superAdmins();
    reviewers = reviewers.filter((p) => p.id !== r.user_id);
    const detail = changes(r);
    for (const p of reviewers) {
      messages.push({
        to: p.email,
        subject: `Auris: ${label} from ${who}`,
        text: `${who} (${r.user_email ?? "no email"}) has asked for a ${label}` +
          ` at ${await clinicName(r.clinic_id)}.\n` +
          (detail ? `\n${detail}\n` : "") +
          (r.reason ? `\nReason given: ${r.reason}\n` : "") +
          `\nOpen Auris and go to Approvals to decide.\n`,
      });
    }
  } else if (event.type === "INSERT" && r.status === "flagged") {
    for (const p of await superAdmins()) {
      messages.push({
        to: p.email,
        subject: "Auris: an email address was changed without approval",
        text: `The login email of ${who} changed without an approved request.\n\n` +
          `${changes(r)}\n\nCheck it in Auris under Approvals.\n`,
      });
    }
  } else if (
    event.type === "UPDATE" && old?.status === "pending" &&
    ["approved", "rejected", "completed"].includes(r.status) && r.user_email
  ) {
    // Tell the person who asked, unless they switched alerts off.
    let wantsAlerts = true;
    if (r.user_id) {
      const { data } = await db.from("profiles")
        .select("email_alerts").eq("id", r.user_id).maybeSingle();
      wantsAlerts = data?.email_alerts !== false;
    }
    if (wantsAlerts || r.kind === "delete") {
      const outcome = r.status === "rejected" ? "was not approved" : "was approved";
      const next = r.status !== "rejected" && r.kind === "email"
        ? "\nOpen Auris, go to your profile and press Confirm new email to finish.\n"
        : r.kind === "delete" && r.status !== "rejected"
        ? "\nYour Auris account has been deleted.\n"
        : "";
      messages.push({
        to: r.user_email,
        subject: `Auris: your ${label} ${outcome}`,
        text: `Your ${label} ${outcome}.\n` +
          (r.decision_note ? `\nNote from the reviewer: ${r.decision_note}\n` : "") +
          next,
      });
    }
  }

  if (messages.length === 0) return new Response("nothing to send");

  const transport = nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user: smtpUser, pass: smtpPass },
  });
  const from = `Auris <${smtpUser}>`;
  const failures: string[] = [];
  for (const m of messages) {
    try {
      await transport.sendMail({ from, ...m });
    } catch (e) {
      failures.push(`${m.to}: ${e}`);
    }
  }
  return new Response(
    JSON.stringify({ sent: messages.length - failures.length, failures }),
    { headers: { "Content-Type": "application/json" } },
  );
});
