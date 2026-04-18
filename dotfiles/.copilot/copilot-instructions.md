<!-- GSD Configuration — managed by gsd-core installer -->

# Instructions for GSD

- Use the gsd-core skill when the user asks for GSD or uses a `gsd-*` command.
- Treat `/gsd-...` or `gsd-...` as command invocations and load the matching file from `.github/skills/gsd-*`.
- When a command says to spawn a subagent, prefer a matching custom agent from `.github/agents`.
- Do not apply GSD workflows unless the user explicitly asks for them.
- After completing any `gsd-*` command or deliverable, offer the next step through `ask_user` until the user indicates they are done.
<!-- /GSD Configuration -->

<!-- jsh-text-only -->

# Text-only operation

Vision is unavailable. Never use image-reading, screenshot, canvas, rendered-page, or other vision-capable tools. Never send image input to a model or delegate visual inspection.

For images, screenshots, PDFs, canvases, rendered browser pages, or image-only notebook output, request source text, DOM or accessibility data, logs, or a textual description instead.

Do not pass image or video file paths directly to terminal tools because VS Code can embed recognized media in the tool result. When textual metadata is required, use a script that accepts a directory and emits text without exposing media files as attachments.

<!-- /jsh-text-only -->

<!-- rtk-instructions v2 -->

# RTK — Token-Optimized CLI

Always prefix shell commands with `rtk`.

Use `rtk gain`, `rtk gain --history`, and `rtk discover` directly. Use `rtk proxy <command>` when raw output is required.

<!-- /rtk-instructions -->
