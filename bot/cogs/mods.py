"""
/mods command group — sync, import-preset.
"""

import logging
import re
from datetime import datetime

import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils

logger = logging.getLogger(__name__)

_PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")


async def _deny(interaction: discord.Interaction) -> None:
    embed = discord.Embed(
        title="Access Denied",
        description="You need the Server-Admin role to use this command.",
        color=discord.Color.red(),
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


async def _reject_invalid_profile(interaction: discord.Interaction, profile: str) -> bool:
    """Reject profile names before they are passed to the remote PowerShell host."""
    if profile == "_all" or _PROFILE_NAME_RE.fullmatch(profile):
        return False

    embed = discord.Embed(
        title="Invalid Profile",
        description="Profile names may only contain letters, numbers, underscores, and hyphens.",
        color=discord.Color.red(),
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)
    return True


async def _reply(
    interaction: discord.Interaction,
    title: str,
    code: int,
    output: str,
    fields: dict[str, str] | None = None,
    status_message: discord.Message | None = None,
) -> None:
    """Filter output first, then build embed + send overflow follow-ups."""
    filtered = ssh_helper.filter_output(output)
    # Embed fields max 1024 chars; subtract 10 for ```\n…\n``` wrappers
    embed_chunks   = ssh_helper.split_output(filtered, size=1010) if filtered else ["(no output)"]
    # Remaining overflow goes as plain follow-up messages (2000 char limit)
    overflow_chunks = ssh_helper.split_output(filtered, size=1900) if filtered else []

    color  = discord.Color.green() if code == 0 else discord.Color.red()
    status = "✅ Success" if code == 0 else f"❌ Error (Exit {code})"
    embed  = discord.Embed(title=title, color=color, timestamp=datetime.utcnow())
    embed.add_field(name="Status", value=status, inline=True)

    if fields:
        for name, value in fields.items():
            embed.add_field(name=name, value=value, inline=True)

    embed.add_field(name="Output", value=f"```\n{embed_chunks[0]}\n```", inline=False)

    if status_message is None:
        await interaction.edit_original_response(embed=embed)
    else:
        await status_message.edit(embed=embed)

    # Send any chunks beyond the first as plain follow-up messages
    for chunk in overflow_chunks[1:]:
        if status_message is None:
            await interaction.followup.send(f"```\n{chunk}\n```")
        else:
            await status_message.channel.send(f"```\n{chunk}\n```")


# ── Cog ────────────────────────────────────────────────────────────────────────

class ModsCog(commands.Cog):
    """Mod management commands (/mods group)."""

    mods = app_commands.Group(name="mods", description="Mod management")

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    # ── /mods sync ────────────────────────────────────────────────────────────

    @mods.command(name="sync", description="Download and deploy mods for a profile")
    @app_commands.describe(
        profile="Profile name (e.g. main, star_wars)",
        force="Re-download mods that are already deployed",
    )
    async def mods_sync(
        self, interaction: discord.Interaction, profile: str, force: bool = False
    ) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)
        if await _reject_invalid_profile(interaction, profile):
            return

        await interaction.response.defer(thinking=True)
        logger.info("mods sync requested by %s — profile: %s force: %s", interaction.user, profile, force)

        extra = f"-Profile {profile}" + (" -Force" if force else "")
        code, out = await ssh_helper.run_ps_file("mods/Sync-Mods.ps1", extra)
        await _reply(
            interaction,
            "Sync Mods",
            code,
            out,
            fields={"Profile": f"`{profile}`", "Force": "Yes" if force else "No"},
        )

    # ── /mods update ─────────────────────────────────────────────────────────

    @mods.command(name="update", description="Check for and deploy Workshop mod updates")
    @app_commands.describe(
        profile="Profile name (e.g. main, star_wars)",
        restart_server="Restart the profile automatically when updates are found",
        check_only="Only report pending updates without downloading them",
    )
    async def mods_update(
        self,
        interaction: discord.Interaction,
        profile: str,
        restart_server: bool = False,
        check_only: bool = False,
    ) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)
        if await _reject_invalid_profile(interaction, profile):
            return
        if profile == "_all" and restart_server:
            embed = discord.Embed(
                title="Invalid Update Options",
                description="Automatic restart requires one concrete profile, not `_all`.",
                color=discord.Color.red(),
            )
            await interaction.response.send_message(embed=embed, ephemeral=True)
            return
        if check_only and restart_server:
            embed = discord.Embed(
                title="Invalid Update Options",
                description="Check-only mode cannot restart the server.",
                color=discord.Color.red(),
            )
            await interaction.response.send_message(embed=embed, ephemeral=True)
            return

        await interaction.response.defer(thinking=True)
        logger.info(
            "mods update requested by %s — profile: %s restart: %s check_only: %s",
            interaction.user,
            profile,
            restart_server,
            check_only,
        )

        extra = f"-Profile {profile} -Update"
        if restart_server:
            extra += " -RestartServer"
        if check_only:
            extra += " -CheckOnly"

        status_message = None
        if interaction.channel is not None:
            started_embed = discord.Embed(
                title="Workshop Update Running",
                description=f"Checking profile `{profile}` and processing required updates...",
                color=discord.Color.yellow(),
                timestamp=datetime.utcnow(),
            )
            try:
                status_message = await interaction.channel.send(embed=started_embed)
            except discord.HTTPException as exc:
                logger.warning("Could not create persistent mod-update status message: %s", exc)

            if status_message is not None:
                try:
                    await interaction.edit_original_response(
                        content=f"Workshop update started: {status_message.jump_url}"
                    )
                except discord.HTTPException as exc:
                    logger.warning("Could not link persistent mod-update status message: %s", exc)

        code, out = await ssh_helper.run_ps_file("mods/Sync-Mods.ps1", extra)
        await _reply(
            interaction,
            "Update Mods",
            code,
            out,
            fields={
                "Profile": f"`{profile}`",
                "Restart": "Yes" if restart_server else "No",
                "Check only": "Yes" if check_only else "No",
            },
            status_message=status_message,
        )

    # ── /mods import-preset ───────────────────────────────────────────────────

    @mods.command(
        name="import-preset",
        description="Upload an Arma 3 Launcher HTML preset and import it into a profile",
    )
    @app_commands.describe(
        profile="Target profile (e.g. main, star_wars)",
        preset_html="HTML export file from the Arma 3 Launcher",
        merge="Keep existing mods and add new ones (instead of replacing)",
        sync_after="Download all mods immediately after import",
    )
    async def mods_import_preset(
        self,
        interaction: discord.Interaction,
        profile: str,
        preset_html: discord.Attachment,
        merge: bool = False,
        sync_after: bool = False,
    ) -> None:
        if not utils.has_admin_auth(interaction):
            return await _deny(interaction)
        if await _reject_invalid_profile(interaction, profile):
            return

        # Validate before deferring so the error shows without a thinking spinner
        if not preset_html.filename.lower().endswith(".html"):
            embed = discord.Embed(
                title="Invalid File",
                description=(
                    "Only `.html` files are accepted.\n"
                    "Arma 3 Launcher → MODS → PRESET → EXPORT"
                ),
                color=discord.Color.red(),
            )
            await interaction.response.send_message(embed=embed, ephemeral=True)
            return

        await interaction.response.defer(thinking=True)
        logger.info(
            "mods import-preset requested by %s — profile: %s file: %s",
            interaction.user, profile, preset_html.filename,
        )

        # 1. Download the HTML from Discord CDN
        try:
            html_bytes = await preset_html.read()
        except discord.HTTPException as exc:
            logger.error("Failed to download attachment: %s", exc)
            embed = discord.Embed(
                title="Download Failed",
                description=f"Could not download the file: {exc}",
                color=discord.Color.red(),
            )
            await interaction.edit_original_response(embed=embed)
            return

        # 2. Upload to the host's presets\ folder via SFTP
        remote_path = (
            config.SCRIPTS_PATH.rstrip("\\") + "\\presets\\" + preset_html.filename
        )
        try:
            await ssh_helper.upload_bytes(html_bytes, remote_path)
            logger.info("Uploaded preset to %s", remote_path)
        except RuntimeError as exc:
            logger.error("SFTP upload failed: %s", exc)
            embed = discord.Embed(
                title="Upload Failed",
                description=str(exc),
                color=discord.Color.red(),
            )
            await interaction.edit_original_response(embed=embed)
            return

        # 3. Run Import-Preset.ps1
        args = f'-PresetFile "{remote_path}" -Profile {profile}'
        if merge:
            args += " -Merge"
        if sync_after:
            args += " -SyncAfter"

        code, out = await ssh_helper.run_ps_file("mods/Import-Preset.ps1", args)
        await _reply(
            interaction,
            "Import Preset",
            code,
            out,
            fields={
                "Profile":    f"`{profile}`",
                "File":       preset_html.filename,
                "Merge":      "Yes" if merge else "No",
                "Sync After": "Yes" if sync_after else "No",
            },
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(ModsCog(bot))
