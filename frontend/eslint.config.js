import js from '@eslint/js';
import globals from 'globals';
import react from 'eslint-plugin-react';

export default [
  { ignores: ['dist/'] },
  js.configs.recommended,
  react.configs.flat.recommended,
  react.configs.flat['jsx-runtime'],
  {
    files: ['**/*.{js,jsx}'],
    languageOptions: { ecmaVersion: 2022, sourceType: 'module', globals: globals.browser },
    settings: { react: { version: 'detect' } },
    rules: { 'react/prop-types': 'off' },
  },
  // config files run in Node
  { files: ['*.config.js'], languageOptions: { globals: globals.node } },
];
