# Moderation: reports, blocks, child safety, ghost archive

Google Play requires that users can report content and users and block
people, and that we act on reports. This is how it works in Duhuze and what
the admin does.

## How users report and block

| Where | What they can do |
| --- | --- |
| Post ⋮ (not their own) | Report post, Block this person |
| Profile ⋮ | Report, Block / Unblock |
| Chat ⋯ → Report or block | Report the chat, Block |
| Status viewer ⋮ | Report the status, Block |

- A report saves `reports/{id}`: `reporterId`, `targetType` (post / user / chat / status), `targetId`, `targetOwnerId`, `reason`, `details`, `preview`, `status: "open"`.
- Only admins can read reports (rules). For each new report, `onReportCreated` (`functions/moderation.js`) notifies the admin accounts in `ADMIN_EMAILS`. **Child safety reports are marked URGENT.**
- A block saves `users/{me}/blocked/{them}`. Their posts and statuses are hidden for me, and the rules stop them from sending me messages. They are not told.

## Handling a report (Admin panel)

Use the **Admin panel** in the app (Settings → Admin panel). Who has access,
roles and every button are explained in README → *Admin panel*. In short:

1. Open the report (child safety is always on top).
2. Look at the person and the content shown in the sheet.
3. Choose **Dismiss**, **Remove post/status**, **Suspend user** or **Remove + suspend**, and write a short note.
4. The server does it, marks the report handled and logs it in `admin_events`.

Aim to handle reports within **24 hours**, and child safety reports **at once**.
Firebase console is the fallback, for example for a report type the panel
cannot act on: delete the document by hand, then set the report's `status`.

## Child safety (CSAE): zero tolerance

1. Do **not** download, copy or forward the material.
2. In the Admin panel choose **Remove + suspend** (or **Suspend user** for a chat or profile report).
3. Keep the evidence: **Remove** saves a copy of the post or status in Firestore `evidence/{reportId}` (locked, only visible in Firebase console) and the media files stay in R2. Do not delete the user's chats or ghost copies, because the authorities may need them.
4. Report to **Rwanda Investigation Bureau (RIB)**. If the material is online elsewhere, also report it to the international hotline (INHOPE / NCMEC CyberTipline).
5. Write what you did in the report (`adminNote`).

The public page about this is `site/child-safety.html`. Play Console asks
for it.

## Ghost message archive

For a report that needs ghost messages (threats, abuse, fraud), see
README → *Critical: ghost message archive*:

```powershell
cd functions
node scripts/open-ghost-archive.js --users a@example.com b@example.com --reason "report <reportId>"
```

Every opening is logged in `admin_events`. Delete the exported file in
`functions/ghost-exports/` when the case is closed.

## Account deletion and evidence

When a user deletes their account, `deleteAccount` removes their data, but
keeps their ghost copies 90 more days (`deleteAfter`) for safety cases;
`purgeDeletedAccountData` deletes them afterwards. If a case is still open
(e.g. a police request), remove the `deleteAfter` field from those
`ghost_archive` documents so they are kept until the case ends, then delete
them by hand.
