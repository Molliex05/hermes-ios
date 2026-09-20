"""Official Hermes observer hook. Never changes a turn, model, tool or delivery route."""
from .push_service import record_completion


def register(ctx):
    ctx.register_hook("post_llm_call", record_completion)
