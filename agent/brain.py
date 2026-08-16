"""Turns a chat history into a reply, giving Claude one tool: saving a
durable note to this chat's persistent memory (see memory.py). Kept to one
tool on purpose -- add a sibling entry to TOOLS and a branch in
_run_tool() when a second one is actually needed, not before.
"""
import anthropic

import memory

# Chat replies don't need deep reasoning, and disabling thinking outright
# on Claude Opus 5 has known failure modes (tool calls emitted as plain
# text, <thinking> tags leaking into output) -- low effort keeps latency
# and cost down while leaving thinking on.
EFFORT = "low"
MAX_TOOL_ITERATIONS = 5

TOOLS = [
    {
        "name": "update_memory",
        "description": (
            "Save a short, durable note that should persist into future, "
            "separate conversations with this user -- a stated preference, "
            "an ongoing task, a fact worth remembering. Use file='USER' for "
            "anything about the person you're talking to, or file='MEMORY' "
            "for your own operating notes (things you personally learned "
            "about how to work with this user or environment, not facts "
            "about the user themself). Notes are appended, not edited -- "
            "the oldest note is dropped automatically once the file fills "
            "up, so keep each note to one self-contained sentence. Don't "
            "call this for things already visible in the conversation or "
            "in your existing notes -- only for what's worth carrying "
            "forward past this chat."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "file": {"type": "string", "enum": ["USER", "MEMORY"]},
                "note": {"type": "string", "description": "One self-contained sentence."},
            },
            "required": ["file", "note"],
        },
    }
]


def _first_text(response: anthropic.types.Message) -> str:
    for block in response.content:
        if block.type == "text":
            return block.text
    return "(no text in response)"


def _run_tool(chat_id: str, block) -> str:
    if block.name == "update_memory":
        file = block.input.get("file", "MEMORY")
        note = block.input.get("note", "")
        try:
            memory.append_entry(chat_id, file, note)
            return "saved"
        except ValueError as e:
            return f"error: {e}"
    return f"error: unknown tool {block.name!r}"


def reply(client: anthropic.Anthropic, model: str, persona: str, chat_id: str, history: list[dict]) -> str:
    """history is a list of {"role": "user"|"assistant", "content": str} --
    plain text turns only. Tool use happens inside this call and never
    gets persisted back into history; the memory files are the durable
    carrier, not the raw tool_use/tool_result blocks."""
    memory_block = memory.load_for_prompt(chat_id)
    system_prompt = f"{persona}\n\n{memory_block}" if memory_block else persona

    messages = list(history)
    for _ in range(MAX_TOOL_ITERATIONS):
        response = client.messages.create(
            model=model,
            max_tokens=2048,
            system=system_prompt,
            output_config={"effort": EFFORT},
            tools=TOOLS,
            messages=messages,
        )
        if response.stop_reason != "tool_use":
            return _first_text(response)

        messages.append({"role": "assistant", "content": response.content})
        tool_results = [
            {"type": "tool_result", "tool_use_id": block.id, "content": _run_tool(chat_id, block)}
            for block in response.content
            if block.type == "tool_use"
        ]
        messages.append({"role": "user", "content": tool_results})

    return "(stopped after too many tool calls in a row)"
