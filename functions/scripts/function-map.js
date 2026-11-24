// Prints which Cloud Functions are defined in which file, as JSON:
//   {"social.js": ["notifyOnFollow", ...], "feed.js": [...], "index.js": [...]}
// Used by deploy.ps1 to deploy only the functions whose file changed.
const fs = require("fs");
const path = require("path");
const root = path.join(__dirname, "..");
const all = require(path.join(root, "index.js"));
const map = {};
const taken = new Set();
const files = fs.readdirSync(root).filter((f) => f.endsWith(".js") && f !== "index.js" && f !== ".eslintrc.js");
for (const file of files) {
  const names = Object.keys(require(path.join(root, file))).filter((n) => !n.startsWith("_"));
  map[file] = names;
  names.forEach((n) => taken.add(n));
}
map["index.js"] = Object.keys(all).filter((n) => !n.startsWith("_") && !taken.has(n));
process.stdout.write(JSON.stringify(map));
