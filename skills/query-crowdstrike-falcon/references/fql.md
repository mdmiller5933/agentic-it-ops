# Falcon FQL that works on this tenant

Hosts filters go on `GET /devices/*/devices/v1?filter=`. Alerts filters go in the
**JSON body** of `POST /alerts/combined/alerts/v1`. Spotlight filters are required
query params on `/spotlight/*`.

## Hosts

```text
hostname:'WKS-SN0046'
serial_number:'SN0046'
hostname:'WKS-*'
status:'normal'
status:'contained'
reduced_functionality_mode:'yes'
platform_name:'Windows'
platform_name:'Linux'
product_type_desc:'Workstation'
product_type_desc:'Server'
os_version:'Windows 11'
os_version:'Windows Server 2025'
os_version:'Ubuntu 24.04'
```

Exact hostname and exact serial work. Prefix wildcard `hostname:'WKS-*'` works
(364 hits on 2026-08-19). Mid-string `hostname:'*SN0046*'` is rejected.

Join to Intune / Automox / Rapid7 / ScreenConnect by **serial**, then mention the
Falcon hostname (`WKS-<serial>` after the rename wave). Legacy names still appear
in the static **IT Investigate** group rule.

## Alerts

```text
device.hostname:'WKS-SN0042'
type:'ldt'
status:'new'
severity:>=50
product:'epp'
created_timestamp:>='2026-08-19T00:00:00Z'
```

`hostname:'WKS-...'` against Alerts returns 0; use `device.hostname`.
`product:'ngav'` returned 0 here — EPP detections are `product:'epp'` + `type:'ldt'`.
Lead-context rows use `product:'automated-lead-context'` / `type:'signal'` and have
null severity. Sort with `created_timestamp|desc`.

## Spotlight

```text
status:'open'
cve.severity:'CRITICAL'
cve.severity:'HIGH'
cve.severity:'CRITICAL'+status:'open'
aid:'<32-char device_id>'
hostname:'WKS-SN0026'
```

No wildcard `*`. Pass facets as repeated query params: `facet=cve&facet=host_info&facet=remediation`.
`host_info` includes hostname, OS, platform — not serial. Resolve serial via the Hosts API
using `aid` / `hostname`.
