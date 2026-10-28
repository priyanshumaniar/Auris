# Enabling cloud sync (Supabase)

Auris works fully offline with no account server. Cloud sync is optional and adds:

- the same patient list on several devices,
- off-site backup of test records,
- named accounts with roles enforced by the database.

Everything goes into **your own Supabase project**. There is no Auris server, and no data reaches anyone but you.

> **Before you start:** this is patient health data. Enabling sync makes you the data controller for that project. Check what your jurisdiction requires (India: DPDP Act 2023; EU: GDPR Art. 9; US: HIPAA). Auris does not make your deployment compliant on its own.

Budget about 20 minutes.

---

## Step 1 - Create the project

1. Go to [supabase.com](https://supabase.com) and sign up.
2. **New project**. Give it a name (e.g. `auris-clinic`).
3. Set a strong database password and **save it in your password manager** - it is not recoverable.
4. Pick the region closest to the clinic. For an Indian practice that is usually `ap-south-1 (Mumbai)`.
5. Wait for provisioning (~2 minutes).

---

## Step 2 - Create the tables and security policies

1. In the left sidebar: **SQL Editor** → **New query**.
2. Open `supabase/schema.sql` from this repository, copy **all** of it, and paste it in.
3. Press **Run**.

You should see `Success. No rows returned` (or a small table of results). This creates the `clinics`, `profiles`, `patients`, `sessions`, `thresholds` and `change_requests` tables, the functions the app calls, and - importantly - the row-level security policies that decide who can read and write what.

To confirm: **Table Editor** should now list six tables, each showing "RLS enabled".

---

## Step 3 - Turn off email confirmation

**Do this before creating any account.** By default Supabase emails a confirmation link to every new user. That link points at a hosted web address, and Auris is a desktop/mobile app with no website - so the link goes nowhere and the account is never confirmed.

1. **Authentication** → **Sign In / Providers** → **Email**.
2. Turn **Confirm email** *off*.
3. Save.

This is the right setting for a clinic app: accounts are for a handful of named staff created by the practice, not public self-service sign-ups. Nobody is verifying strangers' addresses.

> If you would rather keep confirmation on, you must instead create each user from **Authentication → Users → Add user** with **Auto Confirm User** ticked. Sign-up from inside the app will not work until confirmation is disabled or a deep link is configured.

---

## Step 4 - Create your account and your first clinic

Auris can serve several clinics from one Supabase project. Each account is in at most one clinic, and only ever sees that clinic's patients.

| Role | Can do |
|---|---|
| `super_admin` | Runs Auris: creates clinics, approves accounts for any clinic. Sees patients only of a home clinic, if one is set. Granted only with SQL. |
| `admin` | Everything in their own clinic, including approving the staff who ask to join it |
| `clinician` | Registers patients and runs tests in their clinic; cannot delete records |
| `viewer` | Reads records and prints reports in their clinic |
| `pending` | Nothing. Every new account starts here |

1. Run the app (Step 5 first, if you have not pointed it at the project yet), tap **Sign Up** and register. You will see **Waiting for approval**: every new account starts with no access.
2. Make yourself the super admin. In **SQL Editor**, with your email:

   ```sql
   update public.profiles set role = 'super_admin'
   where id = (select id from auth.users where email = 'you@example.com');
   ```

3. In the app press **Check again**, then open **Settings → Admin console → Clinics → New clinic** and create your clinic. It gets a join code such as `AUR-7K2PQ`.
4. If you also want to register patients and run tests yourself (needed for Step 6), make that clinic your home clinic, where you act as its admin. Without a home clinic a super admin sees no patients at all. Copy the clinic's id from **Table Editor → clinics**, then:

   ```sql
   update public.profiles set clinic_id = '<the clinic id>'
   where id = (select id from auth.users where email = 'you@example.com');
   ```

<details>
<summary>Doing it from the dashboard instead</summary>

**Authentication → Users → Add user → Create new user**, tick **Auto Confirm User**. The same trigger fires, so the profile (pending) is still created for you.
</details>

---

## Step 4b - If you registered *before* running the schema

Re-running `supabase/schema.sql` backfills a profile, with no access, for every existing user. Then make yourself the super admin with the SQL in Step 4, and sign out and back in.

Nothing works until a user has a profile row, because every security policy reads it. A user with no profile has **no access** - that is deliberate, so a misconfiguration fails closed rather than open.

---

## Step 5 - Point the app at the project

1. **Project Settings** (gear icon) → **API**.
2. Copy the **Project URL** and the **anon / public** key.
3. Open `app/.env` and fill them in:

```
SUPABASE_URL=https://abcdefghijklm.supabase.co
SUPABASE_ANON_KEY=<paste the long anon key here>

CLINIC_NAME=Sharma ENT Clinic
CLINIC_ADDRESS=12 MG Road, Pune 411001
CLINIC_PHONE=+91 98765 43210
```

(Older projects show a long key beginning `ey…`; newer ones a **publishable** key beginning `sb_publishable_`. Either works. Paste the whole thing on one line.)

In cloud mode each report carries the signed-in user's own clinic (name, address, phone, as set in the app). The `CLINIC_*` values are only a fallback, for an account with no clinic; in local-only mode they are what prints.

> ⚠️ **Use the `anon` key only.** It is designed to sit inside client apps and grants nothing on its own - the row-level security policies decide access. The **`service_role`** key on that same page bypasses every policy. It must never go in `.env`, in the app, or in this repository.
>
> `.env` is git-ignored. Do not force-add it.

4. Restart the app completely (a hot reload will not re-read `.env`):

```bash
flutter run
```

---

## Step 6 - Check it works

1. Sign in with the email and password from Step 4. The **Email** field appears instead of **Username** when cloud sync is active - that tells you the app picked up `.env`.
2. The dashboard should show your clinic's name with *"synced to the cloud"*, and your role.
3. Register a test patient and run a short test on yourself.
4. In Supabase, open **Table Editor → patients**. Your patient should be there.
5. **Settings → Sync now** should report *"Everything is up to date"*.
6. To prove two-way sync: install the app on a second device, sign in with the same account, press **Sync now**, and the patient list should appear.

---

## Step 7 - Password reset codes (do this once)

Auris resets passwords with a one-time **code** typed into the app, not a link: a link needs a web page to land on, and Auris is a desktop and mobile app. Supabase's default email only contains a link, so add the code to it:

1. **Authentication → Emails → Reset Password** (called *Email Templates* in older dashboards).
2. Replace the body with something like:
   ```html
   <h2>Reset your Auris password</h2>
   <p>Enter this code in Auris:</p>
   <p style="font-size:24px;letter-spacing:4px"><strong>{{ .Token }}</strong></p>
   <p>If you did not ask for this, ignore this email.</p>
   ```
3. Save. In the app: **Log In → Forgot password?**, enter your email, then the code and a new password.

A code works once and expires (one hour by default). Asking for a new code cancels the previous one.

---

## Step 8 - Google sign-in (optional)

You need three things: a Google OAuth client, the Google provider switched on in Supabase, and the app's return address allowed in Supabase. The app side is already built.

**8a. Google Cloud Console** ([console.cloud.google.com](https://console.cloud.google.com))

1. Select or create a project, then **Google Auth Platform → Branding** (the OAuth consent screen): app name, support email, developer contact. Audience: **External**. While the app is in *Testing*, add your own Google account under **Audience → Test users**.
2. **Clients → Create client**. Application type: **Web application**, not iOS, Android or Desktop. Supabase is the one talking to Google, and it does so as a web server, whichever device the user is on.
3. Under **Authorised redirect URIs** add exactly:
   ```
   https://<your-project-ref>.supabase.co/auth/v1/callback
   ```
   Supabase shows this exact URL on its Google provider page; copy it from there.
4. Create, then copy the **Client ID** and **Client secret**.

**8b. Supabase → Authentication → Sign In / Providers → Google**

Turn it on, paste the Client ID and Client secret, save.

**8c. Supabase → Authentication → URL Configuration → Redirect URLs**

Add:
```
dev.priyanshumaniar.auris://login-callback
```
This is where Supabase sends the user after Google. It is registered as a URL scheme in the app on macOS, iOS and Android, and must match `SupabaseAuthService.oauthRedirectUrl` in `app/lib/data/auth_service.dart`.

**8d. Try it.** Log In → **Continue with Google**. The browser opens, you pick your Google account, the browser asks to open Auris, and the app moves to the dashboard. A first-time Google account starts as **Awaiting approval**, like any other. If a join code was typed on the Sign Up screen first, it is sent as a request to join; otherwise the person enters it on the waiting screen. A clinic admin then approves it (see *Adding clinics and staff* below).

Google sign-in works on Android, iOS and macOS. It is not offered on Windows or Linux, where the browser cannot hand the user back to the app.

If you applied `supabase/schema.sql` before Google sign-in existed, run it once more so new Google accounts get their name (from Google) as the display name. It is safe to re-run.

---

## Step 9 - Profiles, approvals and email alerts

Everyone has a **profile** (person icon on the dashboard, or **Settings → My profile**): name, phone, qualification, registration number, clinic, Clinic ID, join code, email and password. A change to anything others rely on is a **request** that someone else approves; until then the app, the team list and reports keep showing the approved values.

| What is asked | Who approves |
|---|---|
| A staff member's profile or email | Their clinic's admin, or a super admin |
| A clinic admin's own profile or email | A super admin only |
| A clinic's name, address or phone, edited by its admin | A super admin (they print on every report) |
| Joining a clinic | That clinic's admin, or a super admin |
| Moving to another clinic | The new clinic's admin, or a super admin |
| Deleting one's own account | A super admin |
| Leaving a clinic, changing one's password | Nobody: immediate |

A super admin's own changes, and those of an account still waiting to join a clinic, apply at once. Requests wait in **Settings → Clinic and team → Approvals** (clinic admin) and **Admin console → Approvals** (super admin, filterable by clinic and kind); the dashboard shows a banner when any are waiting. Every request is kept, with who decided, when and why.

Steps 9a and 9b are needed for email changes and account deletion. Step 9c (email alerts) is optional; without it, approvers just see the banner when they open the app.

**9a. Email change codes**

1. **Authentication → Sign In / Providers → Email**: turn **Secure email change** off and save. With it on, Supabase sends a code to the old address as well, and the change only completes when both are entered; Auris asks for the new one only, since the old address has already been checked by the approver.
2. **Authentication → Emails → Change Email Address**: replace the body with something like:
   ```html
   <h2>Confirm your new Auris email</h2>
   <p>Enter this code in Auris, under My profile → Confirm new email:</p>
   <p style="font-size:24px;letter-spacing:4px"><strong>{{ .Token }}</strong></p>
   <p>This changes your login to {{ .NewEmail }}. If you did not ask for this, ignore this email.</p>
   ```

Once a change is approved, the user taps **Send code**, then **Enter code**. The profile's email updates by itself.

**9b. The `delete-account` function**

Only Supabase's service key can remove a login, and that key must never be in the app, so deletion runs in an Edge Function.

1. **Edge Functions → Deploy a new function → Via Editor**. Name it exactly `delete-account`.
2. Replace the editor's contents with all of `supabase/functions/delete-account/index.ts` and **Deploy**.
3. Leave **Verify JWT** on (the default): the app calls it as the signed-in super admin, and the function checks that role again itself.

It needs no secrets; Supabase provides the project URL and service key to every function. When a super admin approves a deletion, the login is removed; the account's patients and tests stay with the clinic, and the request stays in the history.

**9c. Email alerts (optional)**

Alerts are sent through Gmail's SMTP server on port 465. You need a Gmail address with 2-step verification and an **app password** (Google Account → Security → App passwords). If you already set up Gmail as Supabase's custom SMTP for sign-in emails, the same address and app password work here.

1. Deploy a second function the same way, named exactly `notify`, from `supabase/functions/notify/index.ts`.
2. Open the function's **Details** (or **Settings**) and turn **Verify JWT** off. The database webhook does not send a user's token; it proves itself with the secret below instead.
3. **Edge Functions → Secrets**, add:
   - `SMTP_USER`: the Gmail address
   - `SMTP_PASS`: its 16-character app password
   - `WEBHOOK_SECRET`: any long random text, for example from a password generator
4. **Database → Webhooks → Create a new hook** (under **Integrations** in newer dashboards):
   - Table: `change_requests`; Events: **Insert** and **Update**
   - Type: **Supabase Edge Functions**, function `notify`, method `POST`
   - HTTP header: name `x-auris-secret`, value the same text as `WEBHOOK_SECRET`
5. Create.

Approvers get an email when a request needs them, and requesters when theirs is approved, turned down or done. Anyone can switch their own alerts off in **My profile → Email alerts**. The function sends through port 465; Supabase blocks 25 and 587 for Edge Functions.

---

## Updating a project set up with an older version

The October 2026 version of Auris stores how each test was run (pre-test checks, retests, skipped frequencies) and marks results at the -10 dB HL floor or not established. That needs two new columns. In the **SQL Editor**, open `supabase/migration_2026_10_test_record.sql`, paste all of it and click **Run**. It only adds the columns, so it is safe to run twice and does not change any existing record or role.

Until it has run, tests still save on the device, but their upload is rejected and retried on the next sync.

## Updating to profiles and approvals (October 2026)

In **SQL Editor**, paste all of `supabase/schema.sql` and **Run** (safe to re-run). It adds the profile fields, the Clinic ID (`CLN-0001`, `CLN-0002`, … in the order clinics were created), the request history, and keeps patients and tests when an account is deleted. People already waiting to join a clinic are put on its Approvals list. Then do Step 9.

## Updating to several clinics (October 2026)

A project set up before this change has one clinic and lets admins manage accounts only with SQL. To update it, in **SQL Editor**:

1. Paste all of `supabase/schema.sql` and click **Run**. It is safe to re-run.
2. Open `supabase/migration_2026_10_multi_clinic.sql`, **change the email address in it to your own account's**, paste all of it and click **Run**. It makes that account a super admin, keeping its current clinic as its home clinic, and lists each clinic's number and join code.

Existing accounts keep their role and clinic. `supabase/migration_2026_10_access.sql` is superseded; do not run it.

## Adding clinics and staff

**A new clinic:** a super admin opens **Settings → Admin console → Clinics → New clinic**, then gives the clinic's first admin access: their account appears under **Accounts → Without a clinic** once they have signed up; tap it, pick the clinic and **Administrator**, and **Approve**.

**Staff of a clinic:** the clinic's admin shares the join code from **Settings → Clinic and team** (or **My profile → My clinic**). Staff enter it when they sign up (or, after signing in with Google, on the waiting screen or in My profile). The request appears under **Clinic and team → Approvals**, where the admin approves it as Administrator, Clinician or Viewer, or turns it down with a reason. The **Team** tab changes members' roles and removes access.

A super admin can do all of this for any clinic from the admin console, and can move an account to another clinic.

**Checking what an account can see:** open `supabase/checks/check_clinic_access.sql`, put the account's email on the marked line, and run the whole file. It shows the role, the clinic, and how many clinics, accounts, patients and tests that account can reach. `other_clinic_patients_visible` must always be 0.

These roles, and the separation between clinics, are enforced by Postgres itself, not just by the app. A modified client talking straight to the REST API still cannot read another clinic's patients, or delete one unless its user is an admin.

---

## Turning cloud sync on for a device already in use

Records made on the device in local-only mode belong to no clinic. When cloud sync is turned on, the first clinician or administrator to sign in on that device uploads them into their own clinic with the next sync. Sign in first with an account of the clinic those records belong to.

## Turning cloud sync back off

Blank both values in `app/.env` and restart. The app reverts to local-only. Nothing is deleted from Supabase, and records downloaded for a cloud clinic stay in the on-device database, but local accounts do not see them: they belong to that clinic. Records made in local-only mode are visible again.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Login says **Username** not **Email** | `.env` was not read. Check it is at `app/.env`, both values are filled, and you did a full restart (not hot reload). |
| Confirmation email arrives but the link does nothing | Expected - Auris has no website for the link to land on. Turn off **Confirm email** (Step 3), then delete the unconfirmed user and register again. |
| Signed in, but the account has no access and nothing changes after **Check again** | The account was created before the schema (and its trigger) was applied, so it has no profile row. Re-run `supabase/schema.sql` - it backfills profiles - then sign out and back in. |
| Signed in but Auris says **Waiting for approval** | Every new account starts there. A clinic admin approves it in **Settings → Clinic and team**, or a super admin in the **Admin console**. For the very first account, use the SQL in Step 4. |
| Admin console or Clinic and team says `Could not find the function` | `supabase/schema.sql` has not been run since the multi-clinic update. Run it again. |
| My profile says `Could not find the function public.submit_profile_change` (or `my_approver`) | `supabase/schema.sql` has not been run since profiles were added. Run it again. |
| **Send code** works but no code arrives, or the email has a link only | The Change Email Address template does not include `{{ .Token }}` (Step 9a). Check spam too. |
| The code is accepted but the email does not change | **Secure email change** is still on, so Supabase is waiting for a second code sent to the old address (Step 9a). Turn it off and ask again. |
| Approving a deletion says `Requested function was not found` | The `delete-account` function is not deployed, or has another name (Step 9b). |
| No email alerts | Check the `notify` function's **Logs** and **Invocations**. `403 forbidden` means the webhook's `x-auris-secret` header and `WEBHOOK_SECRET` differ; `500 no smtp` means `SMTP_USER` or `SMTP_PASS` is missing; `Invalid login` means `SMTP_PASS` is not an app password; a 401 before the function runs means **Verify JWT** is still on (Step 9c). |
| `new row violates row-level security policy` in logs | The signed-in user's role cannot write. Check `profiles.role`. |
| Google sign-in ends on a browser page saying it cannot open the link | `dev.priyanshumaniar.auris://login-callback` is missing from **Redirect URLs** (Step 8c), or the app was not built after the URL scheme was added. Rebuild and run it once. |
| Google says `redirect_uri_mismatch` | The **Authorised redirect URI** in Google Cloud (Step 8a) does not exactly match the callback URL shown on Supabase's Google provider page. |
| Reset email has a link but no code | The Reset Password template does not include `{{ .Token }}` (Step 7). |
| Patients save locally but never appear in Supabase | Open **Settings → Sync now** and read the message. "Still waiting to upload" means the server could not be reached; it retries by itself. "The server refused ... (permission denied)" is a role problem, not a network one: check the account's role and clinic. |
| Second device shows no records | Press **Sync now** on it. Confirm both accounts are in the same clinic, with `supabase/checks/check_clinic_access.sql`. |
| Nothing syncs and there is no error | Check the device is actually online. Queued patients, tests and deletes are sent automatically when connectivity returns. |

---

## What is *not* built yet

- **Making someone a super admin, and setting a home clinic,** is done with SQL only, on purpose. So is removing a super admin's login (Supabase → Authentication → Users).
- **Deleting a clinic** is not offered in the app, because it would remove every one of its records.
- **Deletes do not reach other devices' copies.** A delete made offline is remembered and sent to the server once the device is back online, so the record does not come back. But another device that had already downloaded that record keeps its copy until it is deleted there too.
- **No end-to-end encryption.** Data is encrypted in transit (TLS) and at rest by Supabase, but Auris does not add client-side encryption, so a Supabase administrator could read patient records.
