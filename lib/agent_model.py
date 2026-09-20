"""Conservative model observation from ps command text, never from prompt text."""

import os
import shlex
import sys


def model_from_command(command, agent):
    # ps loses argv boundaries. Only inspect the leading known option prefix;
    # once a prompt/unknown option begins, nothing later is trusted as a flag.
    tokens = shlex.shlex(command, posix=True)
    tokens.whitespace_split = True
    tokens.commenters = ""
    try:
        if os.path.basename(next(tokens, "")) != agent:
            return ""
    except ValueError:
        return ""
    # Free-text/path/config options can contain spaces that ps no longer quotes.
    # Stop on those instead of treating their contents as more options.
    values = {
        "--model", "--permission-mode", "--remote-control-session-name-prefix",
        "--sandbox", "--ask-for-approval", "--remote", "--profile",
        "--reasoning-effort",
    }
    switches = {
        "--yolo", "--dangerously-bypass-approvals-and-sandbox", "--full-auto",
        "--dangerously-skip-permissions", "--remote-control", "--chrome", "--no-chrome",
        "--no-alt-screen", "--search",
    }
    if agent == "codex":
        values.update({"-p", "-m"})
    model = ""
    while True:
        try:
            token = next(tokens, "")
        except ValueError:
            break  # ps may flatten an apostrophe in the prompt; keep prior evidence.
        if not token:
            break
        key, sep, value = token.partition("=")
        if key in values:
            if not sep:
                try:
                    value = next(tokens, "")
                except ValueError:
                    break
                if not value:
                    break
            if key == "--model" or (agent == "codex" and key == "-m"):
                model = value
        elif token not in switches:
            break
    if agent == "claude":
        model = model.removeprefix("claude-").split("[", 1)[0]
    return model


if __name__ == "__main__":
    print(model_from_command(sys.stdin.read(), sys.argv[1]), end="")
