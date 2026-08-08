"""PostRoll AI content generators — OCR, captions, and blog posts.

Generators call Claude through the Anthropic Python SDK, which is METERED per
token: this is a real recurring cost, not free. `claude_client._needs_cli`
routes to the Claude Code CLI instead only when no ANTHROPIC_API_KEY is set, or
when a call asks for a tool the SDK can't provide (WebSearch, WebFetch, Bash).

This docstring used to claim "no API costs", which was never true of the shipped
app: the Swift app stores the key in the Keychain and passes it to every Python
call, so the metered path is always the default (#85).

All generators share the brand voice prompt at postroll/assets/brand-voice.md.
"""
