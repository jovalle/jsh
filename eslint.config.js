// ESLint v9+ configuration
export default [
  {
    files: ['**/*.js'],
    ignores: ['node_modules/**', '.git/**', '.vscode/**', '.config/nvim/**'],
  },
  {
    files: ['eslint.config.js', 'scripts/**/*.js', 'configs/**/*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        // Browser globals
        window: 'readonly',
        document: 'readonly',
        console: 'readonly',
        // Node.js globals
        process: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
        module: 'readonly',
        require: 'readonly',
        exports: 'readonly',
      },
    },
    rules: {
      // Google Style Guide recommendations
      'no-var': 'error',
      'prefer-const': 'error',
      'prefer-arrow-callback': 'warn',
      'arrow-spacing': ['error', { before: true, after: true }],
      'no-trailing-spaces': 'error',
      'eol-last': ['error', 'always'],
      indent: ['error', 2],
      quotes: ['error', 'single', { avoidEscape: true }],
      semi: ['error', 'always'],
      'comma-dangle': ['error', 'always-multiline'],
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
      'no-console': 'off', // Allow console for scripts
    },
  },
];
