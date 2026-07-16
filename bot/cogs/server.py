"""
/server command group — start, stop, status, update.
Includes a persistent live-status embed that updates every 30 s after server start.
"""

import asyncio
import logging
import re
from datetime import datetime, timezone

import a2s
import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils

logger = logging.getLogger(__name__)

# ── helpers ────────────────────────────────────────────────────────────────────

_LIVE_UPDATE_INTERVAL = 30   # seconds between embed refreshes
_LIVE_MAX_RUNTIME     = 48   # hours before auto-stop (safety cap)
_LIVE_START_GRACE     = 300  # seconds to tolerate missing process during startup
_LIVE_MISS_LIMIT      = 3    # consecutive misses after startup before marking offline
_WEBHOOK_TOKEN_ERROR_CODES = {50027, 10015}  # Invalid Webhook Token / Unknown Webhook


def _ps_quote(value: str) -> str:
    """Quote a string for single-quoted PowerShell literals."""
    return "'" + value.replace("'", "''") + "'"


async def _deny(interaction: discord.Interaction) -> None:
    embed = discord.Embed(
        title="Access Denied",
        description="You need the Server-Admin role to use this command.",
        color=discord.Color.red(),
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


async def _reply(
    interaction: discord.Interaction,
    title: str,
    code: int,
    output: str,
    profile: str | None = None,
) -> None:
    """Filter output first, then build embed + send overflow follow-ups."""
    filtered = ssh_helper.filter_output(output)
    # Embed fields max 1024 chars; subtract 10 for ```\n…\n``` wrappers
    embed_chunks    = ssh_helper.split_output(filtered, size=1010) if filtered else ["(no output)"]
    overflow_chunks = ssh_helper.split_output(filtered, size=1900) if filtered else []

    color  = discord.Color.green() if code == 0 else discord.Color.red()
    status = "✅ Success" if code == 0 else f"❌ Error (Exit {code})"
    embed  = discord.Embed(title=title, color=color, timestamp=datetime.now(timezone.utc))

    if profile:
        embed.add_field(name="Profile", value=f"`{profile}`", inline=True)
    embed.add_field(name="Status", value=status, inline=True)
    embed.add_field(name="Output", value=f"```\n{embed_chunks[0]}\n```", inline=False)

    await interaction.edit_original_response(embed=embed)

    for chunk in overflow_chunks[1:]:
        await interaction.followup.send(f"```\n{chunk}\n```")


def _fmt_uptime(seconds: int) -> str:
    hours, rem = divmod(seconds, 3600)
    mins, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h {mins:02d}m {secs:02d}s"
    return f"{mins}m {secs:02d}s"


def _build_live_embed(
    profile: str,
    proc: dict | None,
    a2s_info: dict | None,
) -> discord.Embed:
    """Build the live-status embed from gathered stats."""
    if proc is None:
        embed = discord.Embed(
            title=f"🔴  Server Offline — `{profile}`",
            color=discord.Color.red(),
            timestamp=datetime.now(timezone.utc),
        )
        embed.set_footer(text="Server process has stopped.")
        return embed

    embed = discord.Embed(
        title=f"🟢  Server Online — `{profile}`",
        color=discord.Color.green(),
        timestamp=datetime.now(timezone.utc),
    )

    if a2s_info:
        embed.add_field(
            name="👥  Players",
            value=f"{a2s_info['players']} / {a2s_info['max_players']}",
            inline=True,
        )
        embed.add_field(
            name="🗺️  Mission",
            value=a2s_info["map"] or "—",
            inline=True,
        )
    else:
        embed.add_field(name="👥  Players", value="—", inline=True)
        embed.add_field(name="🗺️  Mission", value="Starting…", inline=True)

    proc_count = proc.get("proc_count", 1)
    cores      = proc.get("cores", 1)
    cpu_pct    = proc.get("cpu_pct", 0.0)
    # Show % of total system; append per-core equivalent for context
    per_core   = round(cpu_pct * cores / 100, 1) if cores else cpu_pct
    cpu_label  = f"{cpu_pct:.1f}%  (~{per_core:.1f} cores)"

    embed.add_field(name="⏱️  Uptime",    value=_fmt_uptime(proc["uptime_s"]),  inline=True)
    embed.add_field(name="💻  CPU",       value=cpu_label,                       inline=True)
    embed.add_field(name="💾  RAM",       value=f"{proc['ram_mb']:,} MB",        inline=True)
    embed.add_field(name="🔢  PID",       value=str(proc["pid"]),                inline=True)
    embed.add_field(name="⚙️  Processes", value=f"{proc_count} ({cores} cores)", inline=True)

    embed.set_footer(text=f"Profile: {profile}  •  CPU & RAM = server + all HCs  •  refresh every {_LIVE_UPDATE_INTERVAL}s")
    return embed


def _build_starting_embed(profile: str, pid: int, miss_count: int) -> discord.Embed:
    """Build a startup/waiting embed while the host process is not visible yet."""
    embed = discord.Embed(
        title=f"🟡  Server Starting — `{profile}`",
        color=discord.Color.yellow(),
        timestamp=datetime.now(timezone.utc),
    )
    embed.add_field(name="👥  Players", value="—", inline=True)
    embed.add_field(name="🗺️  Mission", value="Starting…", inline=True)
    embed.add_field(name="🔢  Expected PID", value=str(pid), inline=True)
    embed.set_footer(text=f"Waiting for server process via SSH • miss {miss_count}")
    return embed


# ── Cog ────────────────────────────────────────────────────────────────────────

class ServerCog(commands.Cog):
    """Arma 3 Server management commands (/server group)."""

    server = app_commands.Group(name="server", description="Arma 3 server management")

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        # profile → running asyncio.Task
        self._live_tasks: dict[str, asyncio.Task] = {}

    async def _edit_live_status_message(
        self,
        channel: discord.abc.Messageable,
        status_msg: discord.Message,
        profile: str,
        embed: discord.Embed,
    ) -> tuple[discord.Message, bool]:
        """Edit the live-status message, replacing stale webhook messages when needed."""
        try:
            await status_msg.edit(embed=embed)
            return status_msg, True
        except discord.NotFound as exc:
            if getattr(exc, "code", None) in _WEBHOOK_TOKEN_ERROR_CODES:
                logger.warning(
                    "Live-status webhook message for %s is stale (%s); posting a fresh channel message.",
                    profile,
                    exc,
                )
                try:
                    return await channel.send(embed=embed), True
                except discord.HTTPException as send_exc:
                    logger.warning("Could not replace live-status message for %s: %s", profile, send_exc)
                    return status_msg, True

            logger.info("Live-status message deleted — stopping loop for %s", profile)
            return status_msg, False
        except discord.HTTPException as exc:
            if getattr(exc, "code", None) in _WEBHOOK_TOKEN_ERROR_CODES or "Invalid Webhook Token" in str(exc):
                logger.warning(
                    "Live-status edit for %s failed because the webhook token is invalid; posting a fresh channel message.",
                    profile,
                )
                try:
                    return await channel.send(embed=embed), True
                except discord.HTTPException as send_exc:
                    logger.warning("Could not replace live-status message for %s: %s", profile, send_exc)
                    return status_msg, True

            logger.warning("Edit failed: %s", exc)
            return status_msg, True

    # ── internal: query process stats via SSH ──────────────────────────────────

    async def _get_proc_stats(self, profile: str, pid: int, port: int) -> dict | None:
        """Return aggregated CPU/RAM/uptime for the server stack, or None if main PID gone.

        Uptime is derived from the main server process (online/offline signal).
        CPU and RAM are summed across ALL arma3* processes (server + HCs).
        """
        profile_dir = f"{config.SCRIPTS_PATH.rstrip('\\')}\\profiles\\{profile}"
        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
            f"$expectedPid = {pid}; "
            f"$profileDir = {_ps_quote(profile_dir)}; "
            f"$port = {port}; "
            "$escapedProfileDir = [WildcardPattern]::Escape($profileDir); "
            "$main = Get-Process -Id $expectedPid -ErrorAction SilentlyContinue; "
            "if ($main -and $main.ProcessName -notlike 'arma3server*') { $main = $null } "
            "if (-not $main) { "
            "  $allArmaServer = @(Get-CimInstance Win32_Process -Filter \"Name LIKE 'arma3server%'\" -EA SilentlyContinue); "
            "  $serverCandidates = @($allArmaServer | Where-Object { "
            "    $cmd = if ($_.CommandLine) { $_.CommandLine } else { '' }; "
            "    $isHeadlessClient = $cmd -match '(^|\\s)-client(\\s|$)'; "
            "    -not $isHeadlessClient -and "
            "    ("
            "      $_.Name -like 'arma3serverprofiling*' -or "
            "      $cmd -like \"*$escapedProfileDir*\" -or "
            "      $cmd -like \"*-port=$port*\""
            "    )"
            "  }); "
            "  $mainCandidate = @($serverCandidates "
            "    | Sort-Object @{Expression={ if ($_.Name -like 'arma3serverprofiling*') { 0 } else { 1 } }}, CreationDate "
            "    | Select-Object -First 1); "
            "  if ($mainCandidate) { "
            "    $main = Get-Process -Id ([int]$mainCandidate[0].ProcessId) -ErrorAction SilentlyContinue; "
            "  } "
            "} "
            "if (-not $main) { 'stopped'; exit } "
            "$up = [math]::Floor(((Get-Date) - $main.StartTime).TotalSeconds); "
            "$mainPid = $main.Id; "
            "$cores = (Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue).NumberOfLogicalProcessors; "
            "if (-not $cores) { $cores = 1 } "
            "$all1 = @(Get-Process -Name 'arma3*' -EA SilentlyContinue); "
            "$snap1 = ($all1 | Measure-Object CPU -Sum).Sum; "
            "if ($null -eq $snap1) { $snap1 = 0 } "
            "Start-Sleep -Milliseconds 1000; "
            "$all = @(Get-Process -Name 'arma3*' -ErrorAction SilentlyContinue); "
            "$snap2 = ($all | Measure-Object CPU -Sum).Sum; "
            "if ($null -eq $snap2) { $snap2 = $snap1 } "
            "$cpuPct = [math]::Round([math]::Max(0, ($snap2 - $snap1)) / (1.0 * [math]::Max($cores,1)) * 100, 1); "
            "$totalRam = [math]::Round(($all | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0); "
            "if ($null -eq $totalRam) { $totalRam = 0 } "
            "$cnt = $all.Count; "
            "\"ok|$mainPid|$cpuPct|$totalRam|$up|$cnt|$cores\""
        )
        code, out = await ssh_helper.run_ps_command(ps)
        for line in out.splitlines():
            line = line.strip()
            if line == "stopped":
                return None
            if re.match(r"^ok\|\d+\|-?[\d.]+\|\d+\|\d+\|\d+\|\d+$", line):
                parts = line.split("|")
                try:
                    return {
                        "pid":        int(parts[1]),
                        "cpu_pct":    float(parts[2]),
                        "ram_mb":     int(parts[3]),
                        "uptime_s":   int(parts[4]),
                        "proc_count": int(parts[5]),
                        "cores":      int(parts[6]),
                    }
                except ValueError:
                    return None
        logger.warning("Could not parse live-status process stats (exit=%s): %r", code, out)
        return None

    # ── internal: A2S query (run in thread — library is synchronous) ──────────

    async def _get_a2s_info(self, host: str, query_port: int) -> dict | None:
        """Query the Arma 3 server via Steam A2S. Returns None if unavailable."""
        try:
            info = await asyncio.to_thread(
                a2s.info, (host, query_port), timeout=2.0
            )
            return {
                "players":     info.player_count,
                "max_players": info.max_players,
                "map":         info.map_name,
            }
        except Exception:
            return None

    # ── internal: read PID + port from host after start ───────────────────────

    async def _get_pid_and_port(self, profile: str) -> tuple[int, int] | None:
        """SSH: read server.pid and Port from profile.json. Returns (pid, port)."""
        base = config.SCRIPTS_PATH.replace("\\", "/")
        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
            f"$serverPid = (Get-Content '{base}/profiles/{profile}/server.pid' "
            f"  -ErrorAction SilentlyContinue | Select-Object -First 1).Trim(); "
            f"$serverPort = (Get-Content '{base}/profiles/{profile}/profile.json' "
            f"  | ConvertFrom-Json).Port; "
            '"$serverPid|$serverPort"'
        )
        _, out = await ssh_helper.run_ps_command(ps)
        # Strip CLIXML noise and grab only the first line that matches pid|port
        for line in out.splitlines():
            m = re.match(r"^(\d+)\|(\d+)$", line.strip())
            if m:
                return int(m.group(1)), int(m.group(2))
        logger.warning("Could not parse pid/port from: %r", out)
        return None

    # ── internal: background live-status loop ─────────────────────────────────

    async def _live_status_loop(
        self,
        channel: discord.abc.Messageable,
        status_msg: discord.Message,
        profile: str,
        pid: int,
        query_port: int,
    ) -> None:
        host        = config.SERVER_HOST
        loop        = asyncio.get_event_loop()
        started_at  = loop.time()
        deadline    = started_at + _LIVE_MAX_RUNTIME * 3600
        stopped     = False
        miss_count  = 0
        saw_running = False

        try:
            while loop.time() < deadline:
                proc     = await self._get_proc_stats(profile, pid, query_port - 1)
                a2s_info = await self._get_a2s_info(host, query_port) if proc else None

                if proc is None:
                    miss_count += 1
                    elapsed = loop.time() - started_at
                    still_starting = not saw_running and elapsed < _LIVE_START_GRACE
                    transient_miss = saw_running and miss_count < _LIVE_MISS_LIMIT

                    if still_starting or transient_miss:
                        logger.info(
                            "Live-status process miss for %s (miss=%d, elapsed=%ds, saw_running=%s)",
                            profile,
                            miss_count,
                            int(elapsed),
                            saw_running,
                        )
                        embed = _build_starting_embed(profile, pid, miss_count)
                    else:
                        embed = _build_live_embed(profile, None, None)
                else:
                    miss_count = 0
                    saw_running = True
                    embed = _build_live_embed(profile, proc, a2s_info)

                status_msg, keep_running = await self._edit_live_status_message(channel, status_msg, profile, embed)
                if not keep_running:
                    return

                if proc is None and not (not saw_running and (loop.time() - started_at) < _LIVE_START_GRACE):
                    if saw_running and miss_count < _LIVE_MISS_LIMIT:
                        await asyncio.sleep(10)
                        continue
                    stopped = True
                    break

                await asyncio.sleep(10 if proc is None else _LIVE_UPDATE_INTERVAL)

        except asyncio.CancelledError:
            # /server stop was called — update embed to offline
            embed = _build_live_embed(profile, None, None)
            await self._edit_live_status_message(channel, status_msg, profile, embed)
            return

        finally:
            self._live_tasks.pop(profile, None)

        if not stopped:
            # Safety-cap reached
            embed = _build_live_embed(profile, None, None)
            await self._edit_live_status_message(channel, status_msg, profile, embed)

    # ── /server start ─────────────────────────────────────────────────────────

    @server.command(name="start", description="Start the server for a profile")
    @app_commands.describe(profile="Profile name (e.g. main, star_wars)")
    async def server_start(self, interaction: discord.Interaction, profile: str) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server start requested by %s — profile: %s", interaction.user, profile)

        code, out = await ssh_helper.run_ps_file("scripts/Start-Server.ps1", f"-Profile {profile}")
        await _reply(interaction, "Start Server", code, out, profile)

        if code != 0:
            return

        # Cancel any previous live-status task for this profile
        if profile in self._live_tasks:
            self._live_tasks[profile].cancel()

        # Brief pause to let the PID file be written
        await asyncio.sleep(2)

        info = await self._get_pid_and_port(profile)
        if info is None:
            logger.warning("Could not start live-status for %s (no PID/port)", profile)
            return

        pid, port   = info
        query_port  = port + 1

        # Post the live-status embed as a normal bot message. Interaction follow-up
        # messages are webhook-backed and their edit token expires.
        init_embed = _build_live_embed(profile, {"cpu_pct": 0.0, "ram_mb": 0, "uptime_s": 0, "proc_count": 1, "cores": 1, "pid": pid}, None)
        init_embed.title = f"🟡  Server Starting — `{profile}`"
        init_embed.color = discord.Color.yellow()

        if interaction.channel is None:
            logger.warning("Could not start live-status for %s (interaction has no channel)", profile)
            return

        status_msg = await interaction.channel.send(embed=init_embed)

        # Launch background task
        task = asyncio.create_task(
            self._live_status_loop(interaction.channel, status_msg, profile, pid, query_port),
            name=f"live-status-{profile}",
        )
        self._live_tasks[profile] = task
        logger.info("Live-status task started for %s (PID %d, query port %d)", profile, pid, query_port)

    # ── /server stop ──────────────────────────────────────────────────────────

    @server.command(name="stop", description="Stop the server for a profile")
    @app_commands.describe(profile="Profile name (e.g. main, star_wars)")
    async def server_stop(self, interaction: discord.Interaction, profile: str) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server stop requested by %s — profile: %s", interaction.user, profile)

        code, out = await ssh_helper.run_ps_file("scripts/Stop-Server.ps1", f"-Profile {profile}")
        await _reply(interaction, "Stop Server", code, out, profile)

        # Signal live-status loop to update to offline
        if profile in self._live_tasks:
            self._live_tasks[profile].cancel()

    # ── /server status ────────────────────────────────────────────────────────

    @server.command(name="status", description="Show running Arma 3 processes")
    async def server_status(self, interaction: discord.Interaction) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server status requested by %s", interaction.user)

        ps = (
            "$ProgressPreference = 'SilentlyContinue'; "
            "Get-Process arma3* -ErrorAction SilentlyContinue "
            "| Select-Object Id,ProcessName,"
            "@{N='CPU(s)';E={[math]::Round($_.CPU,1)}},"
            "@{N='RAM(MB)';E={[math]::Round($_.WorkingSet64/1MB,0)}} "
            "| Format-Table -AutoSize | Out-String"
        )
        code, out = await ssh_helper.run_ps_command(ps)

        embed = discord.Embed(
            title="Server Status",
            color=discord.Color.blue(),
            timestamp=datetime.now(timezone.utc),
        )
        out = out or "No Arma 3 processes running."
        embed.add_field(name="Processes", value=f"```\n{out[:990]}\n```", inline=False)
        await interaction.edit_original_response(embed=embed)

    # ── /server update ────────────────────────────────────────────────────────

    @server.command(name="update", description="Update the Arma 3 dedicated server")
    async def server_update(self, interaction: discord.Interaction) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)

        await interaction.response.defer(thinking=True)
        logger.info("server update requested by %s", interaction.user)

        code, out = await ssh_helper.run_ps_file("setup/Update-Server.ps1")
        await _reply(interaction, "Server Update", code, out)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(ServerCog(bot))
