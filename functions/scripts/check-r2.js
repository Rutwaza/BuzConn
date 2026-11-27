/**
 * Tests your Cloudflare R2 key: writes, reads and deletes a tiny file in
 * both buckets. Tells you in plain words which one is failing.
 *
 *   cd functions
 *   $env:R2_ACCOUNT_ID="..."; $env:R2_ACCESS_KEY_ID="..."; $env:R2_SECRET_ACCESS_KEY="..."
 *   node scripts/check-r2.js
 *
 * (Use the same values you put in Firebase secrets.)
 */
const {S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand} =
  require("@aws-sdk/client-s3");

const BUCKETS = [
  process.env.R2_PUBLIC_BUCKET_NAME || "bussinessfinder-public",
  process.env.R2_PRIVATE_BUCKET_NAME || "bussinessfinder-private",
];

async function main() {
  const {R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY} = process.env;
  if (!R2_ACCOUNT_ID || !R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY) {
    console.error("Set R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY first.");
    process.exit(1);
  }
  const client = new S3Client({
    region: "auto",
    endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
    credentials: {accessKeyId: R2_ACCESS_KEY_ID, secretAccessKey: R2_SECRET_ACCESS_KEY},
  });
  let bad = 0;
  for (const Bucket of BUCKETS) {
    const Key = `_check/${Date.now()}.txt`;
    for (const [name, cmd] of [
      ["write", new PutObjectCommand({Bucket, Key, Body: "ok"})],
      ["read", new GetObjectCommand({Bucket, Key})],
      ["delete", new DeleteObjectCommand({Bucket, Key})],
    ]) {
      try {
        await client.send(cmd);
        console.log(`OK    ${Bucket}  ${name}`);
      } catch (e) {
        bad++;
        console.log(`FAIL  ${Bucket}  ${name}: ${e.name} ${e.message}`);
      }
    }
  }
  console.log(bad ? "\nSomething failed: fix the R2 API token (Object Read & Write on both buckets)." : "\nAll good: R2 key works.");
}

main();
