# CTX Provider Logos

Drop the official provider logo files **here** (inside the CTX target) so they
get bundled and shown across the app via `ProviderIcon`.

Required filenames (rename your files to exactly these):

| Provider   | File             |
|------------|------------------|
| AWS        | `aws.png`        |
| GCP        | `gcp.png`        |
| Azure      | `azure.png`      |
| Kubernetes | `kubernetes.png` (Phase 3) |

Notes:
- PNG with transparency looks best; JPEG also works (keep the `.png`/.jpeg name matching).
- Use each vendor's **official** mark, unmodified (don't recolor/stretch) — brand-guideline requirement.
- If a file is missing, `ProviderIcon` automatically falls back to a monochrome SF Symbol, so the app still builds and runs.

You already have these in `public/` — move/rename them into this folder:
`Amazon-Web-Services-Emblem.png → aws.png`, `GCP.png → gcp.png`,
`microsoft-azure.png → azure.png`, `kubernetes.png → kubernetes.png`.
