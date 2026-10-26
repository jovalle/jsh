"""Keep AI agent clients in parity with conf/agents.json.

Shared MCP servers and skills are declared once and applied to every agent. Anything an agent
has configured that the config neither shares nor keeps is reported as undeclared.
"""

import fnmatch
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import output  # pylint: disable=import-error

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

ROOT = Path(__file__).resolve().parents[2]
KINDS = ("mcp", "plugins", "skills", "agents", "commands")
ENV_REF = re.compile(r"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}")
# The former bin/jagents wrote this marker; keeping it keeps those commands managed.
COMMAND_MARK = "<!-- jagents: generated -->"
PLATFORM = {"darwin": "darwin", "linux": "linux"}.get(sys.platform, "other")


class Failure(Exception):
    """A reconciliation step that could not be completed safely."""


def read_json(path):
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    return json.loads(text) if text.strip() else {}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def read_toml(path):
    if tomllib is None:
        raise Failure("Python 3.11 or later is required to read Codex TOML")
    return tomllib.loads(path.read_text(encoding="utf-8"))


def matches(name, patterns):
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def user_only(manifest):
    text = manifest.read_text(encoding="utf-8", errors="replace")
    match = re.match(r"---\n(.*?)\n---", text, re.DOTALL)
    return bool(
        match
        and re.search(r"^disable-model-invocation:\s*(true|yes|1)\s*$", match.group(1), re.M)
    )


def opencode_servers(data):
    mcp = data.get("mcp", {})
    if isinstance(mcp.get("servers"), dict):
        return mcp["servers"]
    return {key: value for key, value in mcp.items() if key not in ("servers", "timeout")}


def toml_key(key):
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key)


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        pairs = ", ".join(f"{toml_key(k)} = {toml_value(v)}" for k, v in value.items())
        return "{ " + pairs + " }" if pairs else "{}"
    raise Failure(f"cannot write {value!r} as TOML")


def codex_add(path, name, entry):
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = [f"[mcp_servers.{toml_key(name)}]"]
    lines += [f"{toml_key(k)} = {toml_value(v)}" for k, v in entry.items()]
    updated = text.rstrip("\n") + ("\n\n" if text.strip() else "") + "\n".join(lines) + "\n"
    if tomllib is None or tomllib.loads(updated).get("mcp_servers", {}).get(name) != entry:
        raise Failure(f"{path}: could not add mcp_servers.{name} cleanly")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(updated, encoding="utf-8")


def env_name(value):
    match = ENV_REF.fullmatch(value) if isinstance(value, str) else None
    return match.group(1) if match else None


def resolve(value, environment):
    def lookup(match):
        if match.group(1) not in environment:
            raise Failure(f"${{env:{match.group(1)}}} is not set")
        return environment[match.group(1)]

    return ENV_REF.sub(lookup, value)


def render_codex(server):
    env, headers = server.get("env", {}), server.get("headers", {})
    entry = {}
    if "url" in server:
        entry["url"] = server["url"]
        literal = {k: v for k, v in headers.items() if not ENV_REF.search(v)}
        for key, value in headers.items():
            bearer = re.fullmatch(r"Bearer \$\{env:(\w+)\}", value)
            if key.lower() == "authorization" and bearer:
                entry["bearer_token_env_var"] = bearer.group(1)
            elif env_name(value):
                entry.setdefault("env_http_headers", {})[key] = env_name(value)
            elif key not in literal:
                raise Failure(f"Codex cannot reference {key} = {value}")
        if literal:
            entry["http_headers"] = literal
    else:
        entry["command"] = server["command"][0]
        entry["args"] = server["command"][1:]
        forwarded = [k for k, v in env.items() if env_name(v) == k]
        literal = {k: v for k, v in env.items() if not ENV_REF.search(v)}
        if len(forwarded) + len(literal) != len(env):
            raise Failure("Codex forwards environment variables only under the same name")
        if forwarded:
            entry["env_vars"] = forwarded
        if literal:
            entry["env"] = literal
    if server.get("enabled") is False:
        entry["enabled"] = False
    return entry


def render_opencode(server):
    def convert(values):
        return {key: ENV_REF.sub(r"{env:\1}", value) for key, value in values.items()}

    if "url" in server:
        entry = {"type": "remote", "url": server["url"]}
        if server.get("headers"):
            entry["headers"] = convert(server["headers"])
    else:
        entry = {"type": "local", "command": list(server["command"])}
        if server.get("env"):
            entry["environment"] = convert(server["env"])
    entry["enabled"] = server.get("enabled", True)
    return entry


def render_agy(server, environment):
    # Antigravity cannot reference variables, so values are resolved when they are written.
    if "url" in server:
        entry = {"serverUrl": server["url"]}
        if server.get("headers"):
            entry["headers"] = {k: resolve(v, environment) for k, v in server["headers"].items()}
    else:
        entry = {"command": server["command"][0], "args": server["command"][1:]}
        if server.get("env"):
            entry["env"] = {k: resolve(v, environment) for k, v in server["env"].items()}
    entry["disabled"] = server.get("enabled", True) is False
    return entry


class Agents:
    """Validate, apply, and audit the agent clients declared in one config."""

    def __init__(self, home, dry_run, config, environment):
        self.home = home
        self.dry_run = dry_run
        self.config = config
        self.environment = environment

    def expand(self, path):
        path = str(path)
        if path.startswith("~/"):
            return self.home / path[2:]
        return Path(path) if Path(path).is_absolute() else ROOT / path

    def fixed(self, message):
        output.item(message if not self.dry_run else f"would {message}")
        output.count("to update" if self.dry_run else "updated")

    @staticmethod
    def issue(message):
        output.attention(message)
        output.count("issues")

    def selected(self):
        return [a for a in self.config["agents"] if PLATFORM in a.get("os", [PLATFORM])]

    # Client health ---------------------------------------------------------------------

    def installed(self, agent):
        app, command = agent.get("app"), agent.get("command")
        if app and not any(
            (base / app).is_dir() for base in (Path("/Applications"), self.home / "Applications")
        ):
            self.issue(f"{agent['name']}: {app} is not installed; run just install apps")
            return False
        if command and not shutil.which(command):
            self.issue(f"{agent['name']}: `{command}` is not installed; run just install")
            return False
        return True

    def repair_links(self, agent):
        changed = False
        for directory in map(self.expand, agent.get("links", [])):
            if not directory.is_dir():
                continue
            for link in sorted(directory.iterdir()):
                if not link.is_symlink() or link.exists():
                    continue
                if not self.dry_run:
                    link.unlink()
                self.fixed(f"remove broken link {output.tilde(link)}")
                changed = True
        return changed

    def repair_plugins(self, agent):
        # Only local plugin paths are checked; npm plugins are installed by OpenCode on demand.
        path = self.expand(agent["plugins"]) if agent.get("plugins") else None
        if path is None or not path.is_file():
            return False
        data = read_json(path)
        kept = []
        for spec in data.get("plugin", []):
            name = spec[0] if isinstance(spec, list) else spec
            target = None
            if isinstance(name, str) and name.startswith("file://"):
                target = Path(name[len("file://") :])
            elif isinstance(name, str) and name.startswith(("~/", "/")):
                target = self.expand(name)
            elif isinstance(name, str) and name.startswith(("./", "../")):
                target = path.parent / name
            if target is not None and not target.exists():
                self.fixed(f"remove missing plugin {name} from {output.tilde(path)}")
                continue
            kept.append(spec)
        if len(kept) == len(data.get("plugin", [])):
            return False
        if not self.dry_run:
            data["plugin"] = kept
            write_json(path, data)
        return True

    def run_quietly(self, command):
        try:
            return subprocess.run(
                command,
                check=False,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            self.issue(f"`{' '.join(command)}` failed: {error}")
            return None

    def validate(self, agent):
        if not self.installed(agent):
            return
        changed = self.repair_links(agent)
        changed = self.repair_plugins(agent) or changed
        if changed and agent.get("reload") and not self.dry_run:
            result = self.run_quietly(agent["reload"])
            if result is not None and result.returncode != 0:
                self.issue(f"{agent['name']}: `{' '.join(agent['reload'])}` failed after repair")
        summary = "installed"
        if agent.get("check"):
            result = self.run_quietly(agent["check"])
            if result is None:
                return
            lines = (result.stdout + result.stderr).splitlines()
            first = next((line for line in lines if line), "")
            if result.returncode != 0:
                self.issue(f"{agent['name']}: `{' '.join(agent['check'])}` failed: {first}")
                return
            summary = first or summary
        output.current(f"{agent['name']}: {summary}")

    # Shared configuration ----------------------------------------------------------------

    def shared_for(self, agent_id):
        return {
            name: server
            for name, server in self.config.get("mcp", {}).items()
            if agent_id in server.get("agents", [agent_id])
        }

    def shared_skills(self):
        source = self.config.get("skills", {}).get("source")
        if not source or not self.expand(source).is_dir():
            return {}
        return {
            entry.name: entry / "SKILL.md"
            for entry in sorted(self.expand(source).iterdir())
            if (entry / "SKILL.md").is_file()
        }

    def native_mcp(self, source):
        path, fmt = self.expand(source["path"]), source["format"]
        if not path.exists():
            return {}
        if fmt == "codex":
            return read_toml(path).get("mcp_servers", {})
        if fmt == "opencode":
            return opencode_servers(read_json(path))
        return read_json(path).get("mcpServers", {})

    def native_plugins(self, source):
        if isinstance(source, str):
            return self.directory_items(source)
        path, fmt = self.expand(source["path"]), source["format"]
        if not path.exists():
            return {}
        if fmt == "codex":
            return {name: source for name in read_toml(path).get("plugins", {})}
        specs = read_json(path).get("plugin", [])
        return {(spec[0] if isinstance(spec, list) else spec): source for spec in specs}

    def directory_items(self, directory):
        path = self.expand(directory)
        if not path.is_dir():
            return {}
        return {
            entry.stem if entry.is_file() else entry.name: str(entry)
            for entry in sorted(path.iterdir())
            if not entry.name.startswith(".") and entry.name not in ("node_modules", "README.md")
        }

    def inventory(self, agent, kind):
        sources = agent["inventory"].get(kind, [])
        found = {}
        for source in sources if isinstance(sources, list) else [sources]:
            if kind == "mcp":
                found.update({name: source for name in self.native_mcp(source)})
            elif kind == "plugins":
                found.update(self.native_plugins(source))
            else:
                found.update(self.directory_items(source))
        return found

    def declared(self, agent, kind):
        kept = agent.get("keep", {}).get(kind, [])
        if kind == "mcp":
            return set(self.shared_for(agent["id"])), kept
        if kind == "commands" and agent["inventory"].get("skill_commands"):
            names = {name for name, manifest in self.shared_skills().items() if user_only(manifest)}
            return names, kept
        # Every agent already reads the shared skill folder, so per-agent copies only shadow it.
        return set(), kept

    def extras(self):
        found = []
        for agent in self.selected():
            if "inventory" not in agent:
                continue
            for kind in KINDS:
                names, kept = self.declared(agent, kind)
                for name, location in self.inventory(agent, kind).items():
                    if name not in names and not matches(name, kept):
                        where = location["path"] if isinstance(location, dict) else location
                        found.append((f"{agent['id']}:{kind}:{name}", where))
        shared = self.config.get("skills", {})
        if shared.get("path"):
            names, kept = set(self.shared_skills()), shared.get("keep", [])
            for name, location in self.directory_items(shared["path"]).items():
                if name not in names and not matches(name, kept):
                    found.append((f"shared:skills:{name}", location))
        return found

    def add_server(self, source, name, entry):
        path, fmt = self.expand(source["path"]), source["format"]
        if fmt == "codex":
            codex_add(path, name, entry)
            return
        data = read_json(path)
        if fmt == "opencode":
            mcp = data.setdefault("mcp", {})
            (mcp["servers"] if isinstance(mcp.get("servers"), dict) else mcp)[name] = entry
        else:
            data.setdefault("mcpServers", {})[name] = entry
        write_json(path, data)

    def apply_servers(self, agent):
        for source in agent["inventory"].get("mcp", []):
            present = self.native_mcp(source)
            for name, server in self.shared_for(agent["id"]).items():
                if name in present:
                    continue
                try:
                    if source["format"] == "codex":
                        entry = render_codex(server)
                    elif source["format"] == "opencode":
                        entry = render_opencode(server)
                    else:
                        entry = render_agy(server, self.environment)
                    if not self.dry_run:
                        self.add_server(source, name, entry)
                except Failure as error:
                    self.issue(f"{agent['name']}: cannot add {name}: {error}")
                    continue
                self.fixed(f"add MCP server {name} to {agent['name']}")

    def apply_commands(self, agent):
        """Expose user-only shared skills as slash commands where the agent hides them."""
        directory = agent["inventory"].get("skill_commands")
        if not directory:
            return
        for name, manifest in self.shared_skills().items():
            if not user_only(manifest):
                continue
            target = self.expand(directory) / f"{name}.md"
            body = (
                f"---\ndescription: Run the {name} skill\n---\n{COMMAND_MARK}\n"
                f"Read `{self.home / '.agents/skills' / name / 'SKILL.md'}` and follow it.\n\n"
                "$ARGUMENTS\n"
            )
            current = target.read_text(encoding="utf-8") if target.exists() else None
            if current is not None and COMMAND_MARK not in current:
                self.issue(f"{agent['name']}: {output.tilde(target)} is not managed")
                continue
            if current == body:
                continue
            if not self.dry_run:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body, encoding="utf-8")
            self.fixed(f"add /{name} command to {agent['name']}")


def reconcile(home, dry_run, config_path, environment):
    agents = Agents(home, dry_run, json.loads(config_path.read_text()), environment)
    for agent in agents.selected():
        agents.validate(agent)
        if "inventory" in agent:
            agents.apply_servers(agent)
            agents.apply_commands(agent)
    extras = agents.extras()
    for item_id, location in extras:
        output.attention(f"undeclared {item_id}  {output.tilde(location)}")
    if extras:
        output.count("undeclared", len(extras))
        output.note("declare them under keep in conf/agents.json, or remove them from the agent")
