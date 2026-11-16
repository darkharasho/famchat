import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => {
      const migrations = await readD1Migrations(path.join(__dirname, "migrations"));
      return {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            TOKEN_SECRET: "test-token-secret",
            BOOTSTRAP_SECRET: "test-bootstrap-secret",
          },
        },
      };
    }),
  ],
  test: {
    maxWorkers: 2,
    setupFiles: ["./test/apply-migrations.ts"],
  },
});
