// Import ESLint's flat-config helper so the exported array has validated structure.
const { defineConfig } = require("eslint/config");
// Import the official core JavaScript recommended rules maintained by ESLint.
const js = require("@eslint/js");
// Import curated global variable sets so browser and Node globals are recognized correctly.
const globals = require("globals");
// Import React Hooks plugin so hook usage is validated with current recommended rules.
const reactHooks = require("eslint-plugin-react-hooks");
// Import React Refresh helper API so we can use its official flat configs for Vite projects.
const { reactRefresh } = require("eslint-plugin-react-refresh");
// Import Prettier compatibility config so stylistic ESLint rules do not fight formatting output.
const eslintConfigPrettier = require("eslint-config-prettier/flat");

// Export a flat ESLint configuration that is compatible with ESLint v10+.
module.exports = defineConfig([
  // Ignore generated and dependency folders so linting focuses on source files only.
  {
    // Ignore the Vite build output directory.
    ignores: ["build/**", "dist/**", "node_modules/**"],
  },
  // Apply base language options for JavaScript and JSX source files.
  {
    // Target JavaScript source files used by this React UI.
    files: ["**/*.{js,jsx,mjs,cjs}"],
    // Configure parser and globals for modern JavaScript and JSX.
    languageOptions: {
      // Use the latest ECMAScript syntax support available in ESLint.
      ecmaVersion: "latest",
      // Parse files as ES modules for modern import/export usage.
      sourceType: "module",
      // Enable JSX parsing because the UI uses React components.
      parserOptions: {
        // Enable JSX syntax parsing in JavaScript files.
        ecmaFeatures: { jsx: true },
      },
      // Merge browser and Node globals to support app code and tooling code paths.
      globals: {
        // Include browser globals such as window and document for UI code.
        ...globals.browser,
        // Include Node globals such as process for build-time references when present.
        ...globals.node,
      },
    },
  },
  // Include ESLint core recommended correctness rules.
  js.configs.recommended,
  // Include React Hooks recommended rules in flat-config form.
  reactHooks.configs.flat.recommended,
  // Include React Refresh Vite defaults so component export safety rules are applied correctly.
  reactRefresh.configs.vite(),
  // Add project-specific rule customizations on top of shared presets.
  {
    // Customize rule severities and options for this project.
    rules: {
      // Keep double-quote style enforced to match existing code conventions.
      quotes: ["error", "double"],
      // Enforce unused variable checks as errors to keep the codebase warning-free and strict.
      "no-unused-vars": "error",
      // Disable this new strict rule for now because the current codebase intentionally calls state setters in effects.
      "react-hooks/set-state-in-effect": "off",
      // Enforce refresh-safe export patterns as errors while allowing constant exports used by Vite.
      "react-refresh/only-export-components": ["error", { allowConstantExport: true }],
    },
  },
  // Put Prettier compatibility config last so it can disable any formatting-conflicting rules.
  eslintConfigPrettier,
]);
