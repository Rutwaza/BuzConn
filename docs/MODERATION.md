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

## Handling a report (admin)

1. Open Firebase console → Firestore → `reports`, newest first.
2. Look at the target:
   - post → `posts/{targetId}`
   - status → `statuses/{targetId}`
   - user → `users/{targetOwnerId}`
   - chat → `chats/{targetId}`; for chats, use the export function or the ghost archive script (below), and **only for this report**.
3. Decide:
   - **Not a problem** → set the report's `status` to `"dismissed"`.
   - **Remove content** → delete the post or status document, then set the report to `"actioned"`.
   - **Suspend the user** → set `users/{uid}.isActive = false` (also done by the admin function `setEntityActive`). For serious cases, disable the account in Firebase console → Authentication.
4. Write a short note in the report: `adminNote`, `handledAt`.

Aim to handle reports within **24 hours**, and child safety reports **at once**.

## Child safety (CSAE): zero tolerance

1. Do **not** download, copy or forward the material.
2. Disable the account immediately (Authentication → disable user) and hide the content: set `isActive = false`, delete the post or status.
3. Keep the evidence. Do not delete the user's chats or ghost copies, because the authorities may need them.
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
