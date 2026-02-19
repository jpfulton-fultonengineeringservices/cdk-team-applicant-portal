// Copyright 2025-2026 J. Patrick Fulton
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettierConfig from 'eslint-config-prettier';

// ---------------------------------------------------------------------------
// Apache 2.0 license header enforced on all TypeScript source files
// ---------------------------------------------------------------------------

const APACHE_HEADER = `// Copyright 2025-2026 J. Patrick Fulton
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.`;

const licenseHeaderPlugin = {
  rules: {
    'license-header': {
      meta: {
        type: 'problem',
        fixable: 'code',
        schema: [],
        messages: {
          missing: 'File must begin with the Apache 2.0 license header.',
        },
      },
      create(context) {
        return {
          Program() {
            const src = context.sourceCode.getText();
            if (!src.startsWith(APACHE_HEADER)) {
              context.report({
                loc: { line: 1, column: 0 },
                messageId: 'missing',
                fix(fixer) {
                  return fixer.insertTextBeforeRange([0, 0], APACHE_HEADER + '\n\n');
                },
              });
            }
          },
        };
      },
    },
  },
};

export default tseslint.config(
  // Base JS recommended rules
  js.configs.recommended,

  // TypeScript recommended rules
  ...tseslint.configs.recommended,

  // Prettier compatibility (disables style rules that conflict with Prettier)
  prettierConfig,

  // Global ignores
  {
    ignores: [
      'node_modules/**',
      'cdk.out/**',
      'dist/**',
      '**/*.js',
      '**/*.d.ts',
      '!eslint.config.mjs',
    ],
  },

  // TypeScript source files
  {
    files: ['**/*.ts'],
    plugins: {
      'local-rules': licenseHeaderPlugin,
    },
    rules: {
      'local-rules/license-header': 'error',

      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
  },
);
