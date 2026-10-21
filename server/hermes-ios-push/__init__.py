"""Official Hermes observer hooks + the `ios_notify` tool. Never changes a turn, model, tool call or delivery route."""
from .push_service import on_post_llm_call, on_pre_tool_call


def register(ctx):
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    from .ios_notify_tool import DESCRIPTION, SCHEMA, TOOLSET, handle
    ctx.register_tool(name="ios_notify", toolset=TOOLSET, schema=SCHEMA, handler=handle,
                      description=DESCRIPTION, emoji="📲")
