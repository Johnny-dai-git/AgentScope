# vllm-qwen14b handlers

Drop model-specific business code here (prompt rewriting, post-processing,
function-call adapters, etc.). The image copies the whole directory to
`/app/handlers/` so it's available at runtime; reference it from a
custom launcher and update the Deployment's `command:` / `args:` to
invoke that launcher instead of vLLM's stock entrypoint.
