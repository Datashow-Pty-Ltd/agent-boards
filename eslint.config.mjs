import eslint from "@eslint/js";
import { globalIgnores } from "eslint/config";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

export default tseslint.config(
  globalIgnores([
    "**/node_modules/**",
    "**/dist/**",
    "artifacts/**",
    "release/**",
    "apps/web/vendor/**",
    "apps/web/vite.config.js",
    "apps/web/vite.config.d.ts",
  ]),
  { linterOptions: { reportUnusedDisableDirectives: "error" } },
  {
    ...eslint.configs.recommended,
    files: ["**/*.{js,mjs}"],
    languageOptions: {
      ...eslint.configs.recommended.languageOptions,
      globals: globals.node,
    },
  },
  ...tseslint.configs.recommended.map((config) => ({
    ...config,
    files: ["**/*.{ts,tsx}"],
  })),
  {
    files: ["apps/mcp/**/*.ts", "apps/repo-intelligence/**/*.ts", "tests/**/*.ts", "*.config.ts"],
    languageOptions: { globals: globals.node },
  },
  {
    files: ["apps/web/src/**/*.{ts,tsx}"],
    languageOptions: { globals: globals.browser },
    plugins: { "react-hooks": reactHooks },
    rules: {
      ...reactHooks.configs.flat.recommended.rules,
      // Data-loading effects and prop-to-form synchronization are deliberate in
      // this client. The compiler-oriented rule rejects those valid patterns.
      "react-hooks/set-state-in-effect": "off",
      // dnd-kit's callback refs and listener objects are stable hook outputs,
      // but the generic ref rule cannot distinguish them from ref.current reads.
      "react-hooks/refs": "off",
    },
  },
  {
    files: ["**/*.{js,mjs,ts,tsx}"],
    rules: {
      curly: ["error", "multi-line", "consistent"],
      eqeqeq: ["error", "always"],
      "no-duplicate-imports": "error",
      "no-unneeded-ternary": "error",
    },
  },
);
