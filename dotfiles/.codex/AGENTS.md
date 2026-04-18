# RTK

Always prefix shell commands with `rtk`.

Use `rtk gain`, `rtk gain --history`, and `rtk discover` directly. Use `rtk proxy <command>` when raw output is required.

## Text-only operation

Vision is unavailable. Never use image-reading, screenshot, canvas, rendered-page, or other vision-capable tools. Never send image input to a model or delegate visual inspection.

For images, screenshots, PDFs, canvases, rendered browser pages, or image-only notebook output, request source text, DOM or accessibility data, logs, or a textual description instead.

Do not pass image or video file paths directly to terminal tools because clients can embed recognized media in the tool result. When textual metadata is required, use a script that accepts a directory and emits text without exposing media files as attachments.
