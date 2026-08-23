#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawnSync } from "node:child_process";

const DEFAULT_ENV_PATH = "C:\\AI Workspace\\env.local";
const KEEPER_EXE = "C:\\Program Files (x86)\\Keeper Commander\\keeper-commander.exe";
// ScreenConnect connection profile lives in the notes field of this Keeper record.
const KEEPER_SCREENCONNECT_UID = "KEEPERUID00000000000C";
const DEFAULT_KEY_PATH = path.join(os.homedir(), ".ssh", "id_ed25519_contoso_ssh");
const CACHE_DIR = process.env.ENDPOINT_CACHE_DIR ||
  path.join(process.env.TEMP || process.env.TMP || ".", "codex-endpoint-cache");

function parseArgs(argv) {
  const passthroughIndex = argv.indexOf("--");
  const localArgs = passthroughIndex === -1 ? argv : argv.slice(0, passthroughIndex);
  const remoteCommand = passthroughIndex === -1 ? [] : argv.slice(passthroughIndex + 1);
  const args = {
    target: "",
    connect: false,
    user: "",
    identityFile: DEFAULT_KEY_PATH,
    timeoutMs: 7000,
    json: false,
    screenConnectCheck: false,
    authCheck: false,
    remoteCommand,
  };

  for (let i = 0; i < localArgs.length; i += 1) {
    const arg = localArgs[i];
    if (arg === "--connect") args.connect = true;
    else if (arg === "--json") args.json = true;
    else if (arg === "--screenconnect-check") args.screenConnectCheck = true;
    else if (arg === "--auth-check") args.authCheck = true;
    else if (arg === "--user") args.user = String(localArgs[++i] || "").trim();
    else if (arg === "--identity-file") args.identityFile = String(localArgs[++i] || "").trim();
    else if (arg === "--timeout-ms") args.timeoutMs = Number(localArgs[++i] || args.timeoutMs);
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
    else if (!args.target) args.target = arg;
    else throw new Error(`Unexpected argument: ${arg}`);
  }

  if (!args.target) {
    printHelp();
    process.exit(2);
  }
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs < 1000) args.timeoutMs = 7000;
  return args;
}

function printHelp() {
  console.log(`Usage:
  node contoso-ssh-fast-path.mjs HOST_OR_USER_OR_SERIAL
  node contoso-ssh-fast-path.mjs HOST_OR_USER_OR_SERIAL --connect
  node contoso-ssh-fast-path.mjs HOST_OR_USER_OR_SERIAL --connect -- hostname

Options:
  --connect                 Launch ssh after live lookup and reachability checks.
  --screenconnect-check     Run a read-only ScreenConnect IP/sshd check and test those IPs too.
  --auth-check              Run a read-only ScreenConnect authorized_keys/config check.
  --user USER               SSH username. If omitted, ssh uses its local default.
  --identity-file PATH      SSH identity file. Defaults to ~/.ssh/id_ed25519_contoso_ssh.
  --timeout-ms MS           TCP test timeout. Default 7000.
  --json                    Print machine-readable summary only.
`);
}

function parseDotEnv(text) {
  const values = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    values[match[1]] = match[2].replace(/^['"]|['"]$/g, "");
  }
  return values;
}

// Read one field from a Keeper record. Returns "" on any failure so callers can fall back.
// Never logs the value. Calls the .exe directly: keeper.bat has no @echo off and would
// prepend its echoed command line to the captured value.
function keeperField(uid, field) {
  if (!fs.existsSync(KEEPER_EXE)) return "";
  const res = spawnSync(
    KEEPER_EXE,
    ["clipboard-copy", uid, "--field", field, "--output", "stdout"],
    { encoding: "utf8", timeout: 30000, windowsHide: true },
  );
  if (res.status !== 0 || !res.stdout) return "";
  const out = res.stdout.trim();
  // A lapsed SSO session prints a login prompt instead of the value.
  if (!out || /SSO Login URL|keeper-commander\.exe/i.test(out)) return "";
  return out;
}

function loadScreenConnectEnv() {
  const env = { ...process.env };
  const required = [
    "SCREENCONNECT_BASE_URI",
    "SCREENCONNECT_EXTENSION_ID",
    "SCREENCONNECT_RESTFUL_AUTHENTICATION_SECRET",
  ];
  const stillMissing = () => required.filter((key) => !env[key]);

  // 1. Keeper is the source of truth. The record's notes field holds the KEY=value profile.
  if (stillMissing().length) {
    const blob = keeperField(KEEPER_SCREENCONNECT_UID, "notes");
    if (blob) {
      const fromKeeper = parseDotEnv(blob);
      for (const key of required) {
        if (!env[key] && fromKeeper[key]) env[key] = fromKeeper[key];
      }
    }
  }

  // 2. Legacy plaintext fallback. Kept only so a lapsed Keeper session is not a hard stop;
  //    C:\AI Workspace\env.local is readable by any authenticated account, so prefer Keeper.
  if (stillMissing().length && fs.existsSync(DEFAULT_ENV_PATH)) {
    Object.assign(env, parseDotEnv(fs.readFileSync(DEFAULT_ENV_PATH, "utf8")));
  }

  const missing = stillMissing();
  if (missing.length) return null;

  return {
    baseUri: env.SCREENCONNECT_BASE_URI.replace(/\/$/, ""),
    extensionId: env.SCREENCONNECT_EXTENSION_ID,
    secret: env.SCREENCONNECT_RESTFUL_AUTHENTICATION_SECRET,
  };
}

async function screenConnectRest(config, method, args) {
  const response = await fetch(
    `${config.baseUri}/App_Extensions/${config.extensionId}/Service.ashx/${method}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        CTRLAuthHeader: config.secret,
        Origin: config.baseUri,
      },
      body: JSON.stringify(args),
    },
  );
  const text = await response.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  }
  catch {
    body = { raw: text.slice(0, 1000) };
  }
  if (!response.ok) {
    throw new Error(`${method} HTTP ${response.status}: ${JSON.stringify(body).slice(0, 1500)}`);
  }
  return body;
}

function norm(value) {
  return String(value || "").trim().toUpperCase();
}

function addCandidate(candidates, value, source) {
  const address = String(value || "").trim();
  if (!address || address === "{}" || address.toLowerCase() === "null") return;
  if (candidates.some((candidate) => candidate.address.toLowerCase() === address.toLowerCase())) return;
  candidates.push({ address, source });
}

function listify(value) {
  if (Array.isArray(value)) return value;
  if (value && Array.isArray(value.value)) return value.value;
  if (value && typeof value === "object") return Object.values(value).flatMap(listify);
  if (value === null || value === undefined || value === "") return [];
  return [value];
}

function summarizeScreenConnectSession(session) {
  const guest = session.GuestInfo || {};
  const custom = session.CustomProperties || {};
  return {
    source: "screenconnect-live",
    hostName: session.Name || guest.MachineName,
    sessionId: session.SessionID,
    connected: (session.ActiveConnections || []).length > 0,
    activeConnectionCount: (session.ActiveConnections || []).length,
    lastEventTime: session.LastEventTime,
    loggedOnUser: [
      guest.LoggedOnUserDomain,
      guest.LoggedOnUserName,
    ].filter(Boolean).join("\\") || guest.LoggedOnUserName || "",
    serial: guest.MachineSerialNumber || "",
    os: guest.OperatingSystemName || "",
    site: custom.CustomProperty2 || "",
    privateNetworkAddress: guest.PrivateNetworkAddress || "",
    guestNetworkAddress: session.GuestNetworkAddress || "",
  };
}

async function getLiveScreenConnectMatch(target) {
  const config = loadScreenConnectEnv();
  if (!config) return { configMissing: true, matches: [] };

  const sessions = await screenConnectRest(config, "GetSessionsByFilter", ["SessionType = 'Access'"]);
  const needle = norm(target);
  const matches = sessions.filter((session) => {
    const haystack = [
      session.Name,
      session.SessionID,
      session.GuestInfo?.MachineName,
      session.GuestInfo?.LoggedOnUserName,
      session.GuestInfo?.MachineSerialNumber,
      session.CustomProperties?.CustomProperty1,
      session.CustomProperties?.CustomProperty2,
      session.CustomProperties?.CustomProperty3,
      session.CustomProperties?.CustomProperty4,
    ].map(norm);
    return haystack.some((value) => value.includes(needle));
  });
  return { configMissing: false, matches: matches.map(summarizeScreenConnectSession) };
}

function buildEndpointNetworkCommand(marker) {
  return `#!ps
#timeout=180000
#maxlength=80000
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Select-ServiceSafe {
  param([string] $Name)
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if (-not $svc) {
    return [pscustomobject]@{ Name = $Name; Exists = $false; Status = $null; StartType = $null }
  }
  [pscustomobject]@{ Name = $svc.Name; Exists = $true; Status = [string]$svc.Status; StartType = [string]$svc.StartType }
}

$ipConfig = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
  Select-Object InterfaceAlias, InterfaceDescription,
    @{n="IPv4";e={ @($_.IPv4Address | ForEach-Object { $_.IPAddress }) }},
    @{n="IPv6";e={ @($_.IPv6Address | ForEach-Object { $_.IPAddress }) }},
    @{n="Gateway";e={ @($_.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) }},
    @{n="Dns";e={ @($_.DNSServer.ServerAddresses) }})

$listeners = @(Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess,
    @{n="ProcessName";e={ try { (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName } catch { $null } }})

$firewallRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "OpenSSH|sshd|SSH" -or $_.Name -match "OpenSSH|sshd|SSH" } |
  Select-Object DisplayName, Name, Enabled, Direction, Action, Profile)

$result = [ordered]@{
  Marker = "${marker}"
  CollectedAt = (Get-Date).ToString("o")
  ComputerName = $env:COMPUTERNAME
  WhoAmI = (whoami)
  LoggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
  Services = @(
    Select-ServiceSafe -Name "sshd"
    Select-ServiceSafe -Name "ssh-agent"
    Select-ServiceSafe -Name "CatoNetworksVPNService"
  )
  Port22Listeners = $listeners
  FirewallRules = $firewallRules
  IPConfiguration = $ipConfig
}

Write-Output "BEGIN ${marker}"
$result | ConvertTo-Json -Depth 8 -Compress
Write-Output "END ${marker}"
`;
}

function buildEndpointAuthCommand(marker, expectedPublicKey) {
  const encodedPublicKey = Buffer.from(expectedPublicKey.trim(), "utf8").toString("base64");
  return `#!ps
#timeout=30000
#maxlength=30000
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$expectedPublicKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("${encodedPublicKey}"))
$expectedParts = $expectedPublicKey -split "\\s+"
$expectedMaterial = if ($expectedParts.Count -ge 2) { "$($expectedParts[0]) $($expectedParts[1])" } else { $expectedPublicKey }

function Get-AuthFileSummary {
  param([string] $Path)
  $exists = Test-Path -LiteralPath $Path
  $summary = [ordered]@{
    Path = $Path
    Exists = $exists
    LineCount = 0
    ContainsExpectedKey = $false
  }
  if (-not $exists) { return [pscustomobject]$summary }

  $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") })
  $summary.LineCount = $lines.Count
  $summary.ContainsExpectedKey = $false
  foreach ($line in $lines) {
    $parts = $line -split "\\s+"
    $material = if ($parts.Count -ge 2) { "$($parts[0]) $($parts[1])" } else { $line }
    if ($material -eq $expectedMaterial) { $summary.ContainsExpectedKey = $true }
  }
  [pscustomobject]$summary
}

$programDataAuth = Join-Path $env:ProgramData "ssh\\administrators_authorized_keys"
$loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
$profileNames = @()
if ($loggedOnUser -and $loggedOnUser -match "\\\\") {
  $profileNames += ($loggedOnUser -split "\\\\")[-1]
}
$profileNames += "AveryOperatorContrac"
$profileNames = @($profileNames | Where-Object { $_ } | Select-Object -Unique)
$authPaths = @($programDataAuth)
foreach ($profileName in $profileNames) {
  $authPaths += (Join-Path "C:\\Users\\$profileName" ".ssh\\authorized_keys")
}

$configPath = Join-Path $env:ProgramData "ssh\\sshd_config"
$configLines = @()
if (Test-Path -LiteralPath $configPath) {
  $configLines = @(Get-Content -LiteralPath $configPath -ErrorAction SilentlyContinue |
    Where-Object {
      $_ -match "^(\\s*)?(AuthorizedKeysFile|PubkeyAuthentication|PasswordAuthentication|Match\\s+Group|AuthorizedKeysCommand|AllowUsers|DenyUsers)" -or
      $_ -match "administrators_authorized_keys"
    })
}

Write-Output "BEGIN ${marker}"
Write-Output "CollectedAt=$((Get-Date).ToString("o"))"
Write-Output "ComputerName=$env:COMPUTERNAME"
Write-Output "LoggedOnUser=$loggedOnUser"
Write-Output "SshdConfigPath=$configPath"
foreach ($line in $configLines) {
  Write-Output "CONFIG|$($line -replace "\\|", "/")"
}
foreach ($path in $authPaths) {
  $summary = Get-AuthFileSummary -Path $path
  Write-Output "FILE|$($summary.Path)|$($summary.Exists)|$($summary.LineCount)|$($summary.ContainsExpectedKey)"
}
$adminOutput = @(cmd /c "net localgroup administrators" 2>&1)
foreach ($line in $adminOutput) {
  if ($line -and $line.Trim()) {
    Write-Output "ADMIN|$($line -replace "\\|", "/")"
  }
}
Write-Output "END ${marker}"
`;
}

async function pollCommandResults(config, marker, sessionId, timeoutMs) {
  const started = Date.now();
  let lastRows = [];
  while (Date.now() - started < timeoutMs) {
    const report = {
      ReportType: "SessionEvent",
      SelectFieldNames: ["SessionName", "SessionID", "Time", "EventType", "Host", "Data"],
      FilterExpression: `SessionID = '${sessionId}' AND (EventType = 'RanCommand' OR EventType = 'QueuedCommand') AND Data LIKE '%${marker}%'`,
      ItemLimit: 10,
      TimeZoneOffsetMinutes: -300,
    };
    const response = await screenConnectRest(config, "GetReport", [report]);
    const fields = response.FieldNames || [];
    const rows = (response.Items || []).map((item) =>
      Object.fromEntries(fields.map((field, index) => [field, item[index]])));
    lastRows = rows;
    const ranRows = rows.filter((row) => row.EventType === "RanCommand");
    if (ranRows.length) return ranRows[0];
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  throw new Error(`No RanCommand event returned before timeout. Rows seen: ${JSON.stringify(lastRows).slice(0, 1000)}`);
}

function extractJsonFromCommandData(data, marker) {
  const text = String(data || "");
  const begin = `BEGIN ${marker}`;
  const end = `END ${marker}`;
  const beginIndex = text.indexOf(begin);
  const endIndex = text.lastIndexOf(end);
  if (beginIndex === -1 || endIndex === -1 || endIndex <= beginIndex) {
    throw new Error(`Marker block not found. Preview: ${text.slice(0, 1000)}`);
  }
  return JSON.parse(text.slice(beginIndex + begin.length, endIndex).trim());
}

function extractTextFromCommandData(data, marker) {
  const text = String(data || "");
  const begin = `BEGIN ${marker}`;
  const end = `END ${marker}`;
  const beginIndex = text.indexOf(begin);
  const endIndex = text.lastIndexOf(end);
  if (beginIndex === -1 || endIndex === -1 || endIndex <= beginIndex) {
    throw new Error(`Marker block not found. Preview: ${text.slice(0, 1000)}`);
  }
  return text.slice(beginIndex + begin.length, endIndex).trim();
}

function parseAuthCheckText(text) {
  const result = {
    CollectedAt: "",
    ComputerName: "",
    LoggedOnUser: "",
    SshdConfigPath: "",
    SshdConfigRelevantLines: [],
    AuthorizedKeyFiles: [],
    AdministratorsRaw: [],
  };
  for (const line of text.split(/\r?\n/).map((value) => value.trim()).filter(Boolean)) {
    if (line.startsWith("CONFIG|")) {
      result.SshdConfigRelevantLines.push(line.slice("CONFIG|".length));
      continue;
    }
    if (line.startsWith("FILE|")) {
      const [, filePath, exists, lineCount, containsExpectedKey] = line.split("|");
      result.AuthorizedKeyFiles.push({
        Path: filePath || "",
        Exists: /^true$/i.test(exists || ""),
        LineCount: Number(lineCount || 0),
        ContainsExpectedKey: /^true$/i.test(containsExpectedKey || ""),
      });
      continue;
    }
    if (line.startsWith("ADMIN|")) {
      result.AdministratorsRaw.push(line.slice("ADMIN|".length));
      continue;
    }
    const index = line.indexOf("=");
    if (index !== -1) {
      result[line.slice(0, index)] = line.slice(index + 1);
    }
  }
  return result;
}

async function runEndpointNetworkCheck(sessionId) {
  const config = loadScreenConnectEnv();
  if (!config) throw new Error("ScreenConnect environment fields are missing.");
  const marker = `SC-SSH-NET-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
  await screenConnectRest(config, "SendCommandToSession", [sessionId, buildEndpointNetworkCommand(marker)]);
  const row = await pollCommandResults(config, marker, sessionId, 120000);
  return {
    eventTime: row.Time,
    result: extractJsonFromCommandData(row.Data, marker),
  };
}

async function runEndpointAuthCheck(sessionId, publicKeyPath) {
  const config = loadScreenConnectEnv();
  if (!config) throw new Error("ScreenConnect environment fields are missing.");
  if (!publicKeyPath || !fs.existsSync(publicKeyPath)) {
    throw new Error(`Public key file not found: ${publicKeyPath || "(none)"}`);
  }
  const expectedPublicKey = fs.readFileSync(publicKeyPath, "utf8").trim();
  const marker = `SC-SSH-AUTH-${new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)}-${Math.random().toString(36).slice(2, 8).toUpperCase()}`;
  await screenConnectRest(config, "SendCommandToSession", [sessionId, buildEndpointAuthCommand(marker, expectedPublicKey)]);
  const row = await pollCommandResults(config, marker, sessionId, 120000);
  return {
    eventTime: row.Time,
    result: parseAuthCheckText(extractTextFromCommandData(row.Data, marker)),
  };
}

function readCacheMatches(target) {
  const joinPath = path.join(CACHE_DIR, "endpoint-inventory-join.json");
  if (!fs.existsSync(joinPath)) return [];

  const data = JSON.parse(fs.readFileSync(joinPath, "utf8"));
  const rows = data.endpoints || data.rows || [];
  const needle = norm(target);
  return rows
    .filter((row) => {
      const values = [
        row.host_name,
        row.hostName,
        row.host_key,
        row.serial,
        row.screenconnect_serial,
        row.last_logged_in_user,
        row.screenconnect_logged_on_user,
        row.primary_user,
      ].map(norm);
      return values.some((value) => value.includes(needle));
    })
    .map((row) => ({
      source: "endpoint-cache",
      hostName: row.host_name || row.hostName || row.host_key || "",
      sessionId: row.screenconnect_session_id || row.session_id || "",
      connected: row.screenconnect_connected,
      activeConnectionCount: row.screenconnect_active_connection_count,
      lastEventTime: row.screenconnect_last_event_time,
      loggedOnUser: row.screenconnect_logged_on_user || row.last_logged_in_user || "",
      serial: row.screenconnect_serial || row.serial || "",
      os: row.screenconnect_os || row.os || "",
      site: row.screenconnect_site || row.site || "",
      privateNetworkAddress: row.screenconnect_private_network_address || row.private_ip || row.ip_address || "",
      guestNetworkAddress: row.screenconnect_guest_network_address || row.public_ip || "",
    }));
}

function tcpTest(address, port, timeoutMs) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;
    const finish = (ok, error = "") => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve({ address, port, tcpOpen: ok, error });
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false, "timeout"));
    socket.once("error", (error) => finish(false, error.code || error.message));
    socket.connect(port, address);
  });
}

function sshBannerTest(address, timeoutMs) {
  const timeoutSeconds = Math.max(1, Math.ceil(timeoutMs / 1000));
  const result = spawnSync("ssh-keyscan", ["-T", String(timeoutSeconds), "-p", "22", address], {
    encoding: "utf8",
    windowsHide: true,
  });
  const output = `${result.stdout || ""}${result.stderr || ""}`;
  return {
    sshBanner: result.status === 0 && /ssh-/i.test(output),
    detail: output
      .split(/\r?\n/)
      .filter((line) => line.trim())
      .slice(0, 3)
      .join(" | ")
      .slice(0, 500),
  };
}

function printSummary(summary) {
  if (summary.args.json) {
    console.log(JSON.stringify(summary.publicSummary, null, 2));
    return;
  }

  const match = summary.publicSummary.match;
  if (match) {
    console.log(`Target: ${match.hostName || summary.args.target}`);
    console.log(`Source: ${match.source}`);
    console.log(`Session: ${match.sessionId || "(none)"}`);
    console.log(`Connected: ${match.connected} (${match.activeConnectionCount ?? 0} active)`);
    console.log(`User: ${match.loggedOnUser || "(unknown)"}`);
    console.log(`Serial: ${match.serial || "(unknown)"}`);
    console.log(`OS: ${match.os || "(unknown)"}`);
    console.log(`Last event: ${match.lastEventTime || "(unknown)"}`);
  }
  else {
    console.log(`Target: ${summary.args.target}`);
    console.log("No ScreenConnect/cache match found.");
  }

  console.log("");
  console.log("SSH candidates:");
  for (const candidate of summary.publicSummary.candidates) {
    const status = candidate.tcpOpen
      ? candidate.sshBanner
        ? "ssh-ready"
        : "tcp-open-no-ssh-banner"
      : `closed (${candidate.error || "unreachable"})`;
    console.log(`- ${candidate.address} [${candidate.source}]: ${status}`);
    if (candidate.detail) console.log(`  ${candidate.detail}`);
  }

  if (summary.publicSummary.selectedAddress) {
    console.log("");
    console.log(`Selected: ${summary.publicSummary.selectedAddress}`);
  }

  if (summary.publicSummary.endpointCheck?.result) {
    console.log("");
    const result = summary.publicSummary.endpointCheck.result;
    const sshd = (result.Services || []).find((service) => service.Name === "sshd");
    const cato = (result.Services || []).find((service) => /Cato/i.test(service.Name || ""));
    console.log(`Endpoint check: ${result.CollectedAt || summary.publicSummary.endpointCheck.eventTime}`);
    if (sshd) console.log(`sshd: ${sshd.Status}, ${sshd.StartType}`);
    if (cato) console.log(`Cato service: ${cato.Exists ? `${cato.Status}, ${cato.StartType}` : "not found"}`);
  }

  if (summary.publicSummary.authCheck?.result) {
    console.log("");
    const result = summary.publicSummary.authCheck.result;
    console.log(`Auth check: ${result.CollectedAt || summary.publicSummary.authCheck.eventTime}`);
    console.log("Relevant sshd_config lines:");
    for (const line of result.SshdConfigRelevantLines || []) console.log(`  ${line}`);
    console.log("Authorized key files:");
    for (const file of result.AuthorizedKeyFiles || []) {
      if (!file.Exists) continue;
      console.log(`- ${file.Path}: lines=${file.LineCount}, contains local key=${file.ContainsExpectedKey}`);
    }
    if (result.AdministratorsRaw?.length) {
      console.log("Administrators raw output:");
      for (const line of result.AdministratorsRaw) console.log(`  ${line}`);
    }
  }
  else if (summary.publicSummary.authCheck?.error) {
    console.log("");
    console.log(`Auth check failed: ${summary.publicSummary.authCheck.error}`);
  }
}

function launchSsh(args, address) {
  const sshArgs = [];
  if (args.identityFile && fs.existsSync(args.identityFile)) {
    sshArgs.push("-i", args.identityFile);
  }
  sshArgs.push(
    "-o", "ConnectTimeout=12",
    "-o", "ConnectionAttempts=1",
    "-o", "StrictHostKeyChecking=accept-new",
  );
  sshArgs.push(args.user ? `${args.user}@${address}` : address);
  sshArgs.push(...args.remoteCommand);

  return spawnSync("ssh", sshArgs, { stdio: "inherit", windowsHide: false });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const candidates = [];
  const live = await getLiveScreenConnectMatch(args.target).catch((error) => ({ error: error.message, matches: [] }));
  const cacheMatches = readCacheMatches(args.target);
  const match = live.matches?.[0] || cacheMatches[0] || null;
  let endpointCheck = null;
  let authCheck = null;

  addCandidate(candidates, args.target, "target");
  if (match) {
    addCandidate(candidates, match.privateNetworkAddress, `${match.source}:private`);
    addCandidate(candidates, match.guestNetworkAddress, `${match.source}:guest`);
    addCandidate(candidates, match.hostName, `${match.source}:hostname`);
  }
  for (const cached of cacheMatches.slice(0, 2)) {
    addCandidate(candidates, cached.privateNetworkAddress, `${cached.source}:private`);
    addCandidate(candidates, cached.guestNetworkAddress, `${cached.source}:guest`);
  }

  if (args.screenConnectCheck && live.matches?.[0]?.sessionId) {
    endpointCheck = await runEndpointNetworkCheck(live.matches[0].sessionId).catch((error) => ({ error: error.message }));
    for (const network of endpointCheck.result?.IPConfiguration || []) {
      for (const ip of listify(network.IPv4)) {
        addCandidate(candidates, ip, `screenconnect-command:${network.InterfaceAlias || "IPv4"}`);
      }
    }
  }

  if (args.authCheck && live.matches?.[0]?.sessionId) {
    const publicKeyPath = args.identityFile ? `${args.identityFile}.pub` : "";
    authCheck = await runEndpointAuthCheck(live.matches[0].sessionId, publicKeyPath).catch((error) => ({ error: error.message }));
  }

  const tested = [];
  for (const candidate of candidates) {
    const tcp = await tcpTest(candidate.address, 22, args.timeoutMs);
    const banner = tcp.tcpOpen ? sshBannerTest(candidate.address, args.timeoutMs) : { sshBanner: false, detail: "" };
    tested.push({ ...candidate, ...tcp, ...banner });
  }

  const selected = tested.find((candidate) => candidate.sshBanner) ||
    tested.find((candidate) => candidate.tcpOpen) ||
    null;

  const publicSummary = {
    target: args.target,
    liveLookup: {
      attempted: !live.configMissing,
      error: live.error || "",
      matchCount: live.matches?.length || 0,
    },
    cacheMatchCount: cacheMatches.length,
    match,
    endpointCheck,
    authCheck,
    candidates: tested,
    selectedAddress: selected?.address || "",
    identityFileExists: Boolean(args.identityFile && fs.existsSync(args.identityFile)),
  };

  printSummary({ args, publicSummary });

  if (args.connect) {
    if (!selected) {
      console.error("No reachable SSH candidate was found.");
      process.exit(1);
    }
    const result = launchSsh(args, selected.address);
    process.exit(result.status ?? 1);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || error);
  process.exit(1);
});
