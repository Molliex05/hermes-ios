"""Official Hermes observer hooks + the `ios_notify`, `terminer_appel` and agent-call tools. Never changes a turn, model, tool call or delivery route."""
from .push_service import on_post_llm_call, on_pre_tool_call, on_room_member_activity


def register(ctx):
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("on_room_member_activity", on_room_member_activity)
    from .ios_notify_tool import DESCRIPTION, SCHEMA, TOOLSET, handle
    ctx.register_tool(name="ios_notify", toolset=TOOLSET, schema=SCHEMA, handler=handle,
                      description=DESCRIPTION, emoji="📲")
    from . import voice_call_tool
    ctx.register_tool(name=voice_call_tool.NAME, toolset=voice_call_tool.TOOLSET, schema=voice_call_tool.SCHEMA,
                      handler=voice_call_tool.handle, description=voice_call_tool.DESCRIPTION, emoji="📴")
    from . import call_tools
    for name, schema, handler, description, emoji in call_tools.TOOLS:
        ctx.register_tool(name=name, toolset=call_tools.TOOLSET, schema=schema, handler=handler, description=description, emoji=emoji)
