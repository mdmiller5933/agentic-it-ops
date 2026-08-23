# Retired looping keepalive (it sat in Task Scheduler as Running for days and
# could not self-heal). The scheduled task KeeperSessionKeepAlive now calls:
#   C:\automox-mcp-main\scripts\keeper\Keep-KeeperSession.ps1 -Once
# Reinstall with:
#   pwsh -File C:\automox-mcp-main\scripts\keeper\Install-KeeperSessionKeepAlive.ps1
& 'C:\automox-mcp-main\scripts\keeper\Keep-KeeperSession.ps1' -Once
exit $LASTEXITCODE
