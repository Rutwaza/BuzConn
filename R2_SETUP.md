# Cloudflare R2 setup

The app uses Firebase Auth and Firestore as before. R2 stores media in two separate buckets so the public media domain can never expose private chat files.

## Create the buckets

1. In Cloudflare, create a **public** bucket named `bussinessfinder-public` and attach a custom domain such as `media.your-domain.com`. The custom domain must point to this bucket.
2. Create a second bucket named `bussinessfinder-private`. Keep public access and `r2.dev` access disabled for this bucket.
3. Create an R2 API token with Object Read & Write access scoped to only these two buckets. Keep the S3 Access Key ID and Secret Access Key private.

## Configure Firebase Functions

From the project root, set the two credentials as Firebase secrets:

```powershell
firebase functions:secrets:set R2_ACCESS_KEY_ID --project bussinessfinder-327f5
firebase functions:secrets:set R2_SECRET_ACCESS_KEY --project bussinessfinder-327f5
```

Enter the matching R2 token values when prompted. Create `functions/.env.bussinessfinder-327f5` from `functions/.env.example`, then replace the account ID, bucket names, and public media domain with your actual values. This file is ignored by Git.

Deploy the two media link functions:

```powershell
firebase deploy --only functions:createR2UploadUrl,functions:createR2DownloadUrl --project bussinessfinder-327f5
```

The app calls these functions with the signed-in Firebase user's ID token. Upload links expire after 10 minutes. Private download links expire after 15 minutes, and the download function checks the user's membership in that chat before creating one.

## Access behavior

- Profile photos, business images, post images, and post videos use the public bucket and custom domain.
- Chat images, videos, voice notes, and documents use the private bucket. Firestore stores an `r2://` object reference, not a public URL.
- The private bucket must remain private. Do not attach a public custom domain or enable `r2.dev` for it.
- The app currently caps uploads at 250 MB. Keep Cloudflare R2 credentials out of Flutter configuration and client code.
