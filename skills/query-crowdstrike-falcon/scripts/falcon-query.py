#!/usr/bin/env python3
"""Read-only CrowdStrike Falcon US-2 helper. Never prints client secrets or tokens."""
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_ENV_FILE = r"C:\temp\temp\env.local"
DEFAULT_BASE = "https://api.us-2.crowdstrike.com"
HOST_COMPACT_KEYS = (
    "device_id",
    "hostname",
    "serial_number",
    "status",
    "platform_name",
    "os_version",
    "os_build",
    "os_product_name",
    "product_type_desc",
    "agent_version",
    "reduced_functionality_mode",
    "last_seen",
    "first_seen",
    "local_ip",
    "external_ip",
    "last_login_user",
    "last_login_timestamp",
    "system_manufacturer",
    "system_product_name",
    "provision_status",
    "rtr_state",
    "cid",
)
ALERT_COMPACT_KEYS = (
    "composite_id",
    "id",
    "name",
    "display_name",
    "status",
    "severity",
    "severity_name",
    "type",
    "product",
    "tactic",
    "technique",
    "created_timestamp",
    "updated_timestamp",
    "confidence",
    "description",
    "falcon_host_link",
    "pattern_id",
    "filename",
    "cmdline",
)


class FalconError(RuntimeError):
    pass


def emit(obj: Any) -> None:
    json.dump(obj, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


def parse_env_file(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    labeled = {
        r"Client ID:\s*(\S+)": "client_id",
        r"Secret:\s*(\S+)": "client_secret",
        r"Base URL:\s*(\S+)": "base_url",
    }
    for pattern, key in labeled.items():
        m = re.search(pattern, text, re.I)
        if m:
            out[key] = m.group(1).strip().strip('"').strip("'")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if re.match(r"(?i)client id:|secret:|base url:", line):
            continue
        k, _, v = line.partition("=")
        k = k.strip().upper()
        v = v.strip().strip('"').strip("'")
        if k in {"FALCON_CLIENT_ID", "CLIENT_ID"}:
            out["client_id"] = v
        elif k in {"FALCON_CLIENT_SECRET", "CLIENT_SECRET", "SECRET"}:
            out["client_secret"] = v
        elif k in {"FALCON_BASE_URL", "BASE_URL"}:
            out["base_url"] = v
    return out


def load_creds(env_file: str | None) -> tuple[str, str, str]:
    client_id = os.environ.get("FALCON_CLIENT_ID", "").strip()
    client_secret = os.environ.get("FALCON_CLIENT_SECRET", "").strip()
    base = os.environ.get("FALCON_BASE_URL", "").strip()
    path = env_file or os.environ.get("FALCON_ENV_FILE") or DEFAULT_ENV_FILE
    file_used = None
    if not (client_id and client_secret):
        p = Path(path)
        if not p.is_file():
            raise FalconError(
                f"No FALCON_CLIENT_ID/FALCON_CLIENT_SECRET in the environment and env file not found: {p}"
            )
        parsed = parse_env_file(p)
        client_id = client_id or parsed.get("client_id", "")
        client_secret = client_secret or parsed.get("client_secret", "")
        base = base or parsed.get("base_url", "")
        file_used = str(p)
    base = (base or DEFAULT_BASE).rstrip("/")
    if not client_id or not client_secret:
        raise FalconError("Falcon client id or secret is empty")
    # Stash path only for auth metadata; never return the secret.
    os.environ["_FALCON_ENV_FILE_USED"] = file_used or "(process environment)"
    return client_id, client_secret, base


def http(method: str, url: str, data: bytes | None, headers: dict[str, str], timeout: int = 60) -> tuple[int, Any]:
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, {}
            return resp.status, json.loads(raw.decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            return e.code, {"errors": [{"message": raw[:300].decode("utf-8", "replace")}]}


def falcon_err(obj: Any) -> str | None:
    errs = (obj or {}).get("errors") if isinstance(obj, dict) else None
    if not errs:
        return None
    return " | ".join(f"{e.get('code')}:{e.get('message')}" for e in errs[:3])


class Falcon:
    def __init__(self, client_id: str, client_secret: str, base: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.base = base
        self.token = None
        self.expires_in = None
        self._groups = None
        self._prevention = None
        self._sensor_update = None

    def authenticate(self) -> None:
        status, obj = http(
            "POST",
            f"{self.base}/oauth2/token",
            urllib.parse.urlencode(
                {"client_id": self.client_id, "client_secret": self.client_secret}
            ).encode(),
            {
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            },
        )
        if status >= 400 or "access_token" not in obj:
            raise FalconError(f"OAuth token failed HTTP {status}: {falcon_err(obj) or obj}")
        self.token = obj["access_token"]
        self.expires_in = obj.get("expires_in")

    def _auth_headers(self) -> dict[str, str]:
        if not self.token:
            self.authenticate()
        return {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}

    def get(self, path: str) -> tuple[int, Any]:
        if not path.startswith("/"):
            raise FalconError("path must start with /")
        return http("GET", f"{self.base}{path}", None, self._auth_headers())

    def post(self, path: str, payload: dict[str, Any]) -> tuple[int, Any]:
        if not path.startswith("/"):
            raise FalconError("path must start with /")
        return http(
            "POST",
            f"{self.base}{path}",
            json.dumps(payload).encode(),
            {**self._auth_headers(), "Content-Type": "application/json"},
        )

    def require_ok(self, status: int, obj: Any, what: str) -> Any:
        if status >= 400:
            raise FalconError(f"{what} failed HTTP {status}: {falcon_err(obj) or obj}")
        return obj

    def query_total(self, path: str) -> int | None:
        status, obj = self.get(path)
        if status >= 400:
            return None
        return ((obj.get("meta") or {}).get("pagination") or {}).get("total")

    def group_map(self) -> dict[str, str]:
        if self._groups is None:
            status, obj = self.get("/devices/combined/host-groups/v1?limit=100")
            self.require_ok(status, obj, "host groups")
            self._groups = {g.get("id"): g.get("name") for g in obj.get("resources") or []}
        return self._groups

    def prevention_map(self) -> dict[str, str]:
        if self._prevention is None:
            status, obj = self.get("/policy/combined/prevention/v1?limit=100")
            self.require_ok(status, obj, "prevention policies")
            self._prevention = {p.get("id"): p.get("name") for p in obj.get("resources") or []}
        return self._prevention

    def sensor_update_map(self) -> dict[str, str]:
        if self._sensor_update is None:
            status, obj = self.get("/policy/combined/sensor-update/v1?limit=100")
            self.require_ok(status, obj, "sensor-update policies")
            self._sensor_update = {p.get("id"): p.get("name") for p in obj.get("resources") or []}
        return self._sensor_update

    def compact_host(self, host: dict[str, Any], full: bool = False) -> dict[str, Any]:
        if full:
            row = dict(host)
        else:
            row = {k: host.get(k) for k in HOST_COMPACT_KEYS}
        gmap = self.group_map()
        row["group_names"] = [gmap.get(gid, gid) for gid in (host.get("groups") or [])]
        policies = host.get("device_policies") or {}
        prev = (policies.get("prevention") or {}) if isinstance(policies, dict) else {}
        su = (policies.get("sensor_update") or {}) if isinstance(policies, dict) else {}
        row["prevention_policy"] = self.prevention_map().get(prev.get("policy_id"), prev.get("policy_id"))
        row["sensor_update_policy"] = self.sensor_update_map().get(su.get("policy_id"), su.get("policy_id"))
        row["uninstall_protection"] = su.get("uninstall_protection")
        row["rfm"] = host.get("reduced_functionality_mode")
        return row

    def compact_alert(self, alert: dict[str, Any]) -> dict[str, Any]:
        row = {k: alert.get(k) for k in ALERT_COMPACT_KEYS}
        device = alert.get("device") or {}
        if isinstance(device, dict):
            row["hostname"] = device.get("hostname")
            row["device_id"] = device.get("device_id")
            row["local_ip"] = device.get("local_ip")
        else:
            row["hostname"] = alert.get("hostname")
        return row

    def compact_vuln(self, vuln: dict[str, Any]) -> dict[str, Any]:
        cve = vuln.get("cve") or {}
        host = vuln.get("host_info") or {}
        apps = vuln.get("apps") or []
        app_names = []
        for app in apps[:5]:
            if isinstance(app, dict):
                app_names.append(app.get("product_name_version") or app.get("product_name_normalized"))
        return {
            "id": vuln.get("id"),
            "aid": vuln.get("aid"),
            "status": vuln.get("status"),
            "cve": cve.get("id") if isinstance(cve, dict) else None,
            "severity": cve.get("severity") if isinstance(cve, dict) else None,
            "base_score": cve.get("base_score") if isinstance(cve, dict) else None,
            "exprt_rating": cve.get("exprt_rating") if isinstance(cve, dict) else None,
            "exploit_status": cve.get("exploit_status") if isinstance(cve, dict) else None,
            "hostname": host.get("hostname") if isinstance(host, dict) else None,
            "os_version": host.get("os_version") if isinstance(host, dict) else None,
            "platform": host.get("platform") if isinstance(host, dict) else None,
            "apps": app_names,
            "created_timestamp": vuln.get("created_timestamp"),
            "updated_timestamp": vuln.get("updated_timestamp"),
        }


def quote_ident(value: str) -> str:
    if re.search(r"['\"\\]", value):
        raise FalconError("identifier contains quotes; pass an FQL --filter instead")
    return value


def cmd_auth(falcon: Falcon) -> dict[str, Any]:
    falcon.authenticate()
    return {
        "ok": True,
        "base_url": falcon.base,
        "client_id_len": len(falcon.client_id),
        "client_id_prefix": falcon.client_id[:6] + "…",
        "token_len": len(falcon.token or ""),
        "expires_in": falcon.expires_in,
        "env_file": os.environ.get("_FALCON_ENV_FILE_USED"),
        "note": "This client is read-only. Token value is not printed.",
    }


def cmd_summary(falcon: Falcon) -> dict[str, Any]:
    falcon.authenticate()
    host_totals = {}
    for label, fql in [
        ("all", None),
        ("windows", "platform_name:'Windows'"),
        ("mac", "platform_name:'Mac'"),
        ("linux", "platform_name:'Linux'"),
        ("workstation", "product_type_desc:'Workstation'"),
        ("server", "product_type_desc:'Server'"),
        ("normal", "status:'normal'"),
        ("contained", "status:'contained'"),
        ("rfm", "reduced_functionality_mode:'yes'"),
        ("hidden", None),
    ]:
        if label == "all":
            host_totals[label] = falcon.query_total("/devices/queries/devices/v1?limit=1")
        elif label == "hidden":
            host_totals[label] = falcon.query_total("/devices/queries/devices-hidden/v1?limit=1")
        else:
            host_totals[label] = falcon.query_total(
                "/devices/queries/devices/v1?limit=1&filter=" + urllib.parse.quote(fql)
            )

    def hosts_for(fql: str) -> list[dict[str, Any]]:
        status, obj = falcon.get(
            "/devices/combined/devices/v1?limit=20&filter=" + urllib.parse.quote(fql)
        )
        falcon.require_ok(status, obj, fql)
        return [falcon.compact_host(h) for h in obj.get("resources") or []]

    groups = []
    status, gobj = falcon.get("/devices/combined/host-groups/v1?limit=100")
    falcon.require_ok(status, gobj, "groups")
    for g in gobj.get("resources") or []:
        groups.append(
            {
                "id": g.get("id"),
                "name": g.get("name"),
                "group_type": g.get("group_type"),
                "assignment_rule": g.get("assignment_rule"),
                "description": g.get("description"),
            }
        )

    alert_totals = {}
    for label, fql in [
        ("all", ""),
        ("new", "status:'new'"),
        ("ldt", "type:'ldt'"),
        ("ldt_new", "type:'ldt'+status:'new'"),
        ("severity_ge_50", "severity:>=50"),
        ("epp", "product:'epp'"),
    ]:
        status, obj = falcon.post(
            "/alerts/combined/alerts/v1",
            {"filter": fql, "limit": 1, "sort": "created_timestamp|desc"},
        )
        if status >= 400:
            alert_totals[label] = {"error": falcon_err(obj)}
        else:
            alert_totals[label] = ((obj.get("meta") or {}).get("pagination") or {}).get("total")

    spotlight = {}
    for sev in ("CRITICAL", "HIGH", "MEDIUM", "LOW"):
        spotlight[sev] = falcon.query_total(
            "/spotlight/queries/vulnerabilities/v1?limit=1&filter="
            + urllib.parse.quote(f"cve.severity:'{sev}'+status:'open'")
        )

    return {
        "hosts": host_totals,
        "contained_hosts": hosts_for("status:'contained'"),
        "rfm_hosts": hosts_for("reduced_functionality_mode:'yes'"),
        "groups": groups,
        "alerts": alert_totals,
        "spotlight_open": spotlight,
        "prevention_policies": [
            {"id": i, "name": n} for i, n in sorted(falcon.prevention_map().items(), key=lambda x: x[1] or "")
        ],
        "sensor_update_policies": [
            {"id": i, "name": n} for i, n in sorted(falcon.sensor_update_map().items(), key=lambda x: x[1] or "")
        ],
        "alert_note": "Most status:'new' rows are automated-lead-context signals, not EPP detections. Use type:'ldt' or severity:>=50 for detections.",
    }


def cmd_hosts(falcon: Falcon, filter_fql: str | None, limit: int, offset: int, full: bool) -> dict[str, Any]:
    qs = [f"limit={limit}", f"offset={offset}"]
    if filter_fql:
        qs.append("filter=" + urllib.parse.quote(filter_fql))
    status, obj = falcon.get("/devices/combined/devices/v1?" + "&".join(qs))
    falcon.require_ok(status, obj, "hosts")
    resources = [falcon.compact_host(h, full=full) for h in obj.get("resources") or []]
    return {
        "total": ((obj.get("meta") or {}).get("pagination") or {}).get("total"),
        "returned": len(resources),
        "filter": filter_fql,
        "resources": resources,
    }


def cmd_host(falcon: Falcon, query: str, full: bool) -> dict[str, Any]:
    q = quote_ident(query.strip())
    attempts: list[tuple[str, str]] = []
    if re.fullmatch(r"[0-9a-fA-F]{32}", q):
        attempts.append(("ids", q))
    attempts.append(("serial_number", f"serial_number:'{q}'"))
    attempts.append(("hostname", f"hostname:'{q}'"))
    if not q.upper().startswith("WKS-") and re.fullmatch(r"[A-Za-z0-9-]{5,16}", q):
        attempts.append(("bids_hostname", f"hostname:'WKS-{q}'"))

    seen_ids: set[str] = set()
    matches: list[dict[str, Any]] = []
    tried = []
    for label, spec in attempts:
        if label == "ids":
            status, obj = falcon.get(f"/devices/entities/devices/v2?ids={spec}")
        else:
            status, obj = falcon.get(
                "/devices/combined/devices/v1?limit=20&filter=" + urllib.parse.quote(spec)
            )
        tried.append({"via": label, "status": status, "error": falcon_err(obj), "n": len(obj.get("resources") or [])})
        if status >= 400:
            continue
        for host in obj.get("resources") or []:
            did = host.get("device_id")
            if did in seen_ids:
                continue
            seen_ids.add(did)
            matches.append(falcon.compact_host(host, full=full))
    return {"query": q, "tried": tried, "returned": len(matches), "resources": matches}


def cmd_groups(falcon: Falcon) -> dict[str, Any]:
    status, obj = falcon.get("/devices/combined/host-groups/v1?limit=100")
    falcon.require_ok(status, obj, "groups")
    rows = []
    for g in obj.get("resources") or []:
        rows.append(
            {
                "id": g.get("id"),
                "name": g.get("name"),
                "group_type": g.get("group_type"),
                "assignment_rule": g.get("assignment_rule"),
                "description": g.get("description"),
            }
        )
    return {"total": ((obj.get("meta") or {}).get("pagination") or {}).get("total"), "resources": rows}


def cmd_alerts(falcon: Falcon, filter_fql: str, hostname: str | None, limit: int) -> dict[str, Any]:
    fql = filter_fql or ""
    if hostname:
        host_fql = f"device.hostname:'{quote_ident(hostname)}'"
        fql = f"{fql}+{host_fql}" if fql else host_fql
    payload = {"filter": fql, "limit": limit, "sort": "created_timestamp|desc"}
    status, obj = falcon.post("/alerts/combined/alerts/v1", payload)
    falcon.require_ok(status, obj, "alerts")
    resources = [falcon.compact_alert(a) for a in obj.get("resources") or []]
    return {
        "filter": fql,
        "total": ((obj.get("meta") or {}).get("pagination") or {}).get("total"),
        "returned": len(resources),
        "resources": resources,
    }


def cmd_spotlight(falcon: Falcon, filter_fql: str, hostname: str | None, limit: int) -> dict[str, Any]:
    fql = filter_fql or "cve.severity:'CRITICAL'+status:'open'"
    if hostname:
        host = quote_ident(hostname)
        # Spotlight host_info has hostname, not serial. Resolve AID when possible.
        looked = cmd_host(falcon, host, full=False).get("resources") or []
        if looked and looked[0].get("device_id"):
            host_fql = f"aid:'{looked[0]['device_id']}'"
        else:
            host_fql = f"hostname:'{host}'"
        fql = f"{fql}+{host_fql}"
    qs = [
        f"limit={limit}",
        "facet=cve",
        "facet=host_info",
        "facet=remediation",
        "filter=" + urllib.parse.quote(fql),
    ]
    status, obj = falcon.get("/spotlight/combined/vulnerabilities/v1?" + "&".join(qs))
    falcon.require_ok(status, obj, "spotlight")
    resources = [falcon.compact_vuln(v) for v in obj.get("resources") or []]
    return {
        "filter": fql,
        "total": ((obj.get("meta") or {}).get("pagination") or {}).get("total"),
        "returned": len(resources),
        "resources": resources,
    }


def cmd_policies(falcon: Falcon, kind: str) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if kind in ("prevention", "all"):
        status, obj = falcon.get("/policy/combined/prevention/v1?limit=100")
        falcon.require_ok(status, obj, "prevention")
        out["prevention"] = [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "enabled": p.get("enabled"),
                "platform_name": p.get("platform_name"),
                "description": p.get("description"),
            }
            for p in obj.get("resources") or []
        ]
    if kind in ("sensor-update", "all"):
        status, obj = falcon.get("/policy/combined/sensor-update/v1?limit=100")
        falcon.require_ok(status, obj, "sensor-update")
        out["sensor_update"] = [
            {
                "id": p.get("id"),
                "name": p.get("name"),
                "enabled": p.get("enabled"),
                "platform_name": p.get("platform_name"),
                "build": (p.get("settings") or {}).get("build"),
            }
            for p in obj.get("resources") or []
        ]
    return out


def cmd_iocs(falcon: Falcon, filter_fql: str | None, limit: int) -> dict[str, Any]:
    qs = [f"limit={limit}"]
    if filter_fql:
        qs.append("filter=" + urllib.parse.quote(filter_fql))
    status, obj = falcon.get("/iocs/combined/indicator/v1?" + "&".join(qs))
    falcon.require_ok(status, obj, "iocs")
    return {
        "total": ((obj.get("meta") or {}).get("pagination") or {}).get("total"),
        "returned": len(obj.get("resources") or []),
        "resources": obj.get("resources") or [],
    }


def cmd_get(falcon: Falcon, path: str) -> dict[str, Any]:
    if not path.startswith("/"):
        path = "/" + path
    if any(tok in path.lower() for tok in ("/oauth2/token", "client_secret")):
        raise FalconError("refusing to GET a credential endpoint")
    status, obj = falcon.get(path)
    return {"status": status, "error": falcon_err(obj), "body": obj}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Read-only CrowdStrike Falcon US-2 queries")
    p.add_argument("--env-file", default=None, help=f"Credential file (default {DEFAULT_ENV_FILE})")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("auth", help="Prove OAuth works without printing the token")
    sub.add_parser("summary", help="Fleet snapshot: hosts, groups, alerts, Spotlight counts")
    sub.add_parser("groups", help="List host groups")

    ph = sub.add_parser("hosts", help="Search hosts with FQL")
    ph.add_argument("--filter", default=None)
    ph.add_argument("--limit", type=int, default=25)
    ph.add_argument("--offset", type=int, default=0)
    ph.add_argument("--full", action="store_true")

    pho = sub.add_parser("host", help="Look up one hostname, serial, or agent ID")
    pho.add_argument("query")
    pho.add_argument("--full", action="store_true")

    pa = sub.add_parser("alerts", help="Search alerts (POST combined)")
    pa.add_argument("--filter", default="")
    pa.add_argument("--hostname", default=None)
    pa.add_argument("--limit", type=int, default=25)

    ps = sub.add_parser("spotlight", help="Search Spotlight vulnerabilities")
    ps.add_argument("--filter", default="cve.severity:'CRITICAL'+status:'open'")
    ps.add_argument("--hostname", default=None)
    ps.add_argument("--limit", type=int, default=25)

    pp = sub.add_parser("policies", help="List prevention and/or sensor-update policies")
    pp.add_argument("--kind", choices=["prevention", "sensor-update", "all"], default="all")

    pi = sub.add_parser("iocs", help="List custom IOC indicators")
    pi.add_argument("--filter", default=None)
    pi.add_argument("--limit", type=int, default=50)

    pg = sub.add_parser("get", help="Raw GET of a relative Falcon path")
    pg.add_argument("path")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        client_id, client_secret, base = load_creds(args.env_file)
        falcon = Falcon(client_id, client_secret, base)
        if args.cmd == "auth":
            emit(cmd_auth(falcon))
        elif args.cmd == "summary":
            emit(cmd_summary(falcon))
        elif args.cmd == "hosts":
            emit(cmd_hosts(falcon, args.filter, args.limit, args.offset, args.full))
        elif args.cmd == "host":
            emit(cmd_host(falcon, args.query, args.full))
        elif args.cmd == "groups":
            emit(cmd_groups(falcon))
        elif args.cmd == "alerts":
            emit(cmd_alerts(falcon, args.filter, args.hostname, args.limit))
        elif args.cmd == "spotlight":
            emit(cmd_spotlight(falcon, args.filter, args.hostname, args.limit))
        elif args.cmd == "policies":
            emit(cmd_policies(falcon, args.kind))
        elif args.cmd == "iocs":
            emit(cmd_iocs(falcon, args.filter, args.limit))
        elif args.cmd == "get":
            emit(cmd_get(falcon, args.path))
        else:
            raise FalconError(f"unknown command {args.cmd}")
        return 0
    except FalconError as e:
        emit({"ok": False, "error": str(e)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
