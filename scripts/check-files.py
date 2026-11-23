#!/usr/bin/env python3
"""Offline checks of this repository's data files, run by scripts/check.sh.

- config/*.toml: valid TOML; only the keys of twr's relay.toml schema
  (crates/twr-relay/src/server/config.rs, which refuses unknown keys); every [limits] key
  written out; the region, names and ports consistent with the rest of this repository.
- .github/workflows/*.yml: valid YAML.
- cloud-init/relay.yaml.tftpl: rendered the way tofu's templatefile() would be, with the
  variables tofu/main.tf passes, then valid YAML with the embedded files intact.
- known_hosts: comments or "twr-relay-<region> <type> <key>" lines.
- No private keys or DigitalOcean tokens anywhere in the tracked tree.
"""

import base64
import ipaddress
import json
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOMAIN = "relay.twr.tools"
errors = []


def error(msg):
    errors.append(msg)
    print(f"  error: {msg}")


try:
    import yaml
except ImportError:
    yaml = None
    error("PyYAML is not installed (python3-yaml); the YAML checks can't run")

# The relay.toml schema, mirrored from config.rs (read at twr commit ecf7eda9, 2026-11-23).
SCHEMA = {
    "relay": {"hostname", "public_host", "public_port", "region", "listen", "state_dir",
              "metrics_listen", "metrics_public", "phone_suffixes"},
    "tls": {"mode", "acme_contact", "acme_directory", "acme_ca_roots", "cert", "key"},
    "iroh": {"enabled", "hostname", "quic_listen", "listen"},
    "limits": {"phones_per_hub", "phone_connections_per_hub", "monthly_bytes_per_hub",
               "bytes_per_second", "burst_bytes", "idle_seconds", "hello_seconds",
               "hub_hello_seconds", "new_hubs_per_ip_per_hour",
               "phone_attempts_per_ip_per_minute", "pending_per_ip",
               "record_puts_per_ip_per_minute", "pairing_admissions_per_ip_per_hour",
               "pair_admissions_per_ip_per_hour", "max_connections", "max_hubs", "max_records",
               "max_admitted", "record_ttl_seconds"},
    "deny": {"hubs", "endpoints", "addresses"},
}
PORT_HUB_KEYS = {"hub", "listen", "public_port", "allow_unauthenticated"}
TLS_MODES = {"acme", "self-signed", "files"}


def socket_addr(s):
    """host:port or [v6]:port, as Rust's SocketAddr parses it; returns (ip, port)."""
    m = re.fullmatch(r"\[([0-9A-Fa-f:.]+)\]:(\d+)", s) or re.fullmatch(r"([0-9.]+):(\d+)", s)
    if not m:
        raise ValueError(f"{s!r} is not an IP:port socket address")
    port = int(m.group(2))
    if not 0 < port < 65536:
        raise ValueError(f"{s!r}: port out of range")
    return ipaddress.ip_address(m.group(1)), port


def check_config(path):
    print(f"config: {path.relative_to(ROOT)}")
    region = path.stem
    try:
        cfg = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as e:
        error(f"{path.name}: not valid TOML: {e}")
        return
    for section, value in cfg.items():
        if section == "port_hub":
            for i, p in enumerate(value if isinstance(value, list) else [value]):
                for k in set(p) - PORT_HUB_KEYS:
                    error(f"{path.name}: unknown key port_hub[{i}].{k}")
            continue
        if section not in SCHEMA:
            error(f"{path.name}: unknown section [{section}]")
            continue
        if not isinstance(value, dict):
            error(f"{path.name}: {section} is not a table")
            continue
        for k in set(value) - SCHEMA[section]:
            error(f"{path.name}: unknown key {section}.{k}")
    relay, tls, iroh = cfg.get("relay", {}), cfg.get("tls", {}), cfg.get("iroh", {})
    limits, deny = cfg.get("limits", {}), cfg.get("deny", {})

    for k in sorted(SCHEMA["limits"] - set(limits)):
        error(f"{path.name}: limits.{k} is not written out (every limit is stated explicitly)")
    for k, v in limits.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            error(f"{path.name}: limits.{k} must be a positive integer")
    if limits.get("burst_bytes", 65536) < 65536:
        error(f"{path.name}: limits.burst_bytes must be at least 65536")

    if relay.get("region") != region:
        error(f"{path.name}: relay.region is {relay.get('region')!r}, the file name says {region!r}")
    host = f"{region}.{DOMAIN}"
    if relay.get("hostname") != host:
        error(f"{path.name}: relay.hostname should be {host!r}")
    if iroh.get("enabled", True) and iroh.get("hostname", f"iroh.{host}") != f"iroh.{host}":
        error(f"{path.name}: iroh.hostname should be iroh.{host} (covered by *.{region} records)")
    if tls.get("mode", "acme") not in TLS_MODES:
        error(f"{path.name}: tls.mode must be one of {sorted(TLS_MODES)}")
    if tls.get("mode", "acme") == "acme":
        if tls.get("acme_contact") != "mailto:relay-ops@twr.tools":
            error(f"{path.name}: tls.acme_contact should be mailto:relay-ops@twr.tools")
        if "staging" in tls.get("acme_directory", ""):
            error(f"{path.name}: tls.acme_directory is Let's Encrypt staging")

    try:
        for addr in relay.get("listen", ["[::]:443"]):
            if socket_addr(addr)[1] != 443:
                error(f"{path.name}: relay.listen {addr} is not port 443 (the firewalls open 443)")
        if "metrics_listen" in relay:
            ip, port = socket_addr(relay["metrics_listen"])
            if not ip.is_loopback:
                error(f"{path.name}: relay.metrics_listen must be loopback")
            if port != 9469:
                error(f"{path.name}: monitoring/local-check.sh reads the metrics on port 9469")
        if relay.get("metrics_public"):
            error(f"{path.name}: relay.metrics_public must stay false")
        if iroh.get("quic_listen") is not None and socket_addr(iroh["quic_listen"])[1] != 7842:
            error(f"{path.name}: iroh.quic_listen is not UDP 7842 (the firewalls open 7842)")
    except ValueError as e:
        error(f"{path.name}: {e}")

    for a in deny.get("addresses", []):
        try:
            ipaddress.ip_network(a, strict=False)
        except ValueError:
            error(f"{path.name}: deny.addresses entry {a!r} is not an address or prefix")
    for e in deny.get("endpoints", []):
        if not re.fullmatch(r"[0-9a-f]{64}", e):
            error(f"{path.name}: deny.endpoints entry {e!r} is not 64 lowercase hex")


def check_workflows():
    for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
        print(f"yaml: {path.relative_to(ROOT)}")
        if yaml is None:
            continue
        try:
            doc = yaml.safe_load(path.read_text())
        except yaml.YAMLError as e:
            error(f"{path.name}: not valid YAML: {e}")
            continue
        if not isinstance(doc, dict) or "jobs" not in doc:
            error(f"{path.name}: no jobs")
        text = path.read_text()
        for m in re.finditer(r"uses:\s*([^\s#]+)", text):
            ref = m.group(1)
            if not ref.startswith("./") and not re.search(r"@[0-9a-f]{40}$", ref):
                error(f"{path.name}: action {ref} is not pinned by commit SHA")
        if "permissions:" not in text:
            error(f"{path.name}: no permissions: block")


def check_cloud_init():
    tpl_path = ROOT / "cloud-init" / "relay.yaml.tftpl"
    print(f"cloud-init: {tpl_path.relative_to(ROOT)}")
    tpl = tpl_path.read_text()
    main = (ROOT / "tofu" / "main.tf").read_text()
    m = re.search(r"templatefile\(\"\$\{path\.module\}/\.\./cloud-init/relay\.yaml\.tftpl\", \{(.*?)\n  \}\)", main, re.S)
    if not m:
        error("tofu/main.tf: no templatefile() call for cloud-init/relay.yaml.tftpl")
        return
    passed = dict(re.findall(r"^\s*(\w+)\s*=\s*(.+?)\s*$", m.group(1), re.M))
    files = {k: re.fullmatch(r'file\("\$\{path\.module\}/\.\./(.+)"\)', v) for k, v in passed.items()}

    if "%{" in tpl:
        error("relay.yaml.tftpl: template directives (%{...}) are not supported by this check")
    used = set()

    def render(region):
        values = {
            "region": region, "hostname": f"{region}.{DOMAIN}", "reboot_time": "02:00",
            "twr_version": "v0.0.0-check", "acme_contact": "mailto:relay-ops@twr.tools",
            "admin_user": "ops",
            "admin_ssh_public_keys": ["sk-ssh-ed25519@openssh.com AAAAcheck ops@key"],
            "deploy_ssh_public_key": "ssh-ed25519 AAAAcheck deploy",
        }
        for k, fm in files.items():
            if fm:
                rel = fm.group(1).replace("${each.key}", region)
                values[k] = (ROOT / rel).read_text()

        def sub(mm):
            expr = mm.group(1).strip()
            fn = re.fullmatch(r"(jsonencode|base64encode)\((\[?)(\w+)(\]?)\)", expr)
            name = fn.group(3) if fn else expr
            if not re.fullmatch(r"\w+", name):
                error(f"relay.yaml.tftpl: unsupported expression ${{{expr}}}")
                return "X"
            used.add(name)
            if name not in passed:
                error(f"relay.yaml.tftpl: ${{{expr}}} uses {name}, which tofu/main.tf doesn't pass")
                return "X"
            v = values.get(name, "X")
            if fn:
                if fn.group(2):
                    v = [v]
                if fn.group(1) == "jsonencode":
                    return json.dumps(v)
                return base64.b64encode(v.encode()).decode()
            return str(v)

        return re.sub(r"(?<!\$)\$\{([^}]*)\}", sub, tpl)

    for config in sorted((ROOT / "config").glob("*.toml")):
        region = config.stem
        out = render(region)
        if not out.startswith("#cloud-config\n"):
            error("relay.yaml.tftpl: the first line must be #cloud-config")
        size = len(out.encode())
        # DigitalOcean's user_data limit is 64 KiB (unverified); keep well below it.
        if size > 48 * 1024:
            error(f"rendered cloud-init for {region} is {size} bytes, close to the 64 KiB user_data limit")
        print(f"  rendered for {region}: {size} bytes")
        if yaml is None:
            continue
        try:
            doc = yaml.safe_load(out)
        except yaml.YAMLError as e:
            error(f"rendered cloud-init for {region} is not valid YAML: {e}")
            continue
        wf = {f["path"]: f for f in doc.get("write_files", [])}
        for p, src in (("/usr/local/share/twr-infra/install-twr-release.sh", "scripts/install-twr-release.sh"),
                       ("/usr/local/share/twr-infra/twr-release-signing-key.pub", "keys/twr-release-signing-key.pub"),
                       ("/etc/twr-relay/relay.toml", f"config/{region}.toml")):
            f = wf.get(p)
            if not f or f.get("encoding") != "b64":
                error(f"rendered cloud-init for {region}: no b64 write_files entry for {p}")
            elif base64.b64decode(f["content"]) != (ROOT / src).read_bytes():
                error(f"rendered cloud-init for {region}: {p} is not {src}")
        users = {u["name"]: u for u in doc.get("users", []) if isinstance(u, dict)}
        for u in ("ops", "deploy"):
            if u not in users or not users[u].get("ssh_authorized_keys") or not users[u].get("lock_passwd"):
                error(f"rendered cloud-init for {region}: user {u} without keys or with a password")
        if doc.get("ssh_pwauth") is not False or doc.get("disable_root") is not True:
            error(f"rendered cloud-init for {region}: password SSH or root SSH not turned off")
        if "unattended-upgrades" not in doc.get("packages", []):
            error(f"rendered cloud-init for {region}: no unattended-upgrades")
        if not doc.get("runcmd"):
            error(f"rendered cloud-init for {region}: no runcmd")
    for k in sorted(set(passed) - used):
        error(f"tofu/main.tf passes {k} to the template, which doesn't use it")


def check_known_hosts():
    path = ROOT / "known_hosts"
    print(f"known_hosts: {path.relative_to(ROOT)}")
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3 or not re.fullmatch(r"twr-relay-[a-z0-9]+", parts[0]) or "REPLACE_ME" in line:
            error(f"known_hosts:{n}: expected 'twr-relay-<region> <type> <key>'")
        elif parts[1] not in ("ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"):
            error(f"known_hosts:{n}: unexpected key type {parts[1]}")


SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "a private key"),
    (re.compile(r"\bdop_v1_[0-9a-f]{20,}"), "a DigitalOcean token"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}"), "a GitHub token"),
]


def check_no_secrets():
    print("secrets: the whole tree")
    for path in sorted(ROOT.rglob("*")):
        rel = path.relative_to(ROOT)
        if not path.is_file() or rel.parts[0] in (".git", ".terraform") or ".terraform" in rel.parts:
            continue
        if rel.name.endswith((".tfstate", ".tfstate.backup")) or rel.name == "terraform.tfvars":
            continue  # ignored by git; never committed
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for pat, what in SECRET_PATTERNS:
            if pat.search(text) and rel.as_posix() != "scripts/check-files.py":
                error(f"{rel}: looks like it holds {what}")


def main():
    configs = sorted((ROOT / "config").glob("*.toml"))
    if not configs:
        error("no config/*.toml")
    for c in configs:
        check_config(c)
    check_workflows()
    check_cloud_init()
    check_known_hosts()
    check_no_secrets()
    if errors:
        print(f"check-files: {len(errors)} problem(s)")
        return 1
    print("check-files: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
