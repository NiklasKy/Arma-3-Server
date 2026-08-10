"""Background scheduler for idle-only Arma 3 maintenance."""

import asyncio
import contextlib
import logging

from discord.ext import commands

import config
import ssh_helper

logger = logging.getLogger(__name__)


class AutomationCog(commands.Cog):
    """Runs the host-side update cycle at a configured interval."""

    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self._scheduler_task: asyncio.Task[None] | None = None

    async def cog_load(self) -> None:
        if not config.AUTO_UPDATE_ENABLED:
            logger.info("Automatic updates are disabled.")
            return

        self._scheduler_task = asyncio.create_task(
            self._run_scheduler(), name="arma3-auto-update"
        )

    async def cog_unload(self) -> None:
        if self._scheduler_task is None:
            return

        self._scheduler_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._scheduler_task

    async def _run_scheduler(self) -> None:
        await self.bot.wait_until_ready()
        logger.info(
            "Automatic updates enabled: interval=%d minutes, initial_delay=%d seconds.",
            config.AUTO_UPDATE_INTERVAL_MINUTES,
            config.AUTO_UPDATE_INITIAL_DELAY_SECONDS,
        )

        if config.AUTO_UPDATE_INITIAL_DELAY_SECONDS:
            await asyncio.sleep(config.AUTO_UPDATE_INITIAL_DELAY_SECONDS)

        while not self.bot.is_closed():
            await self._run_update_cycle()
            await asyncio.sleep(config.AUTO_UPDATE_INTERVAL_MINUTES * 60)

    async def _run_update_cycle(self) -> None:
        timeout_seconds = config.AUTO_UPDATE_TIMEOUT_MINUTES * 60
        logger.info("Starting automatic update check.")

        try:
            code, output = await asyncio.wait_for(
                ssh_helper.run_ps_file("scripts/Auto-Update.ps1"),
                timeout=timeout_seconds,
            )
        except TimeoutError:
            logger.error(
                "Automatic update timed out after %d minutes.",
                config.AUTO_UPDATE_TIMEOUT_MINUTES,
            )
            return
        except Exception:
            logger.exception("Automatic update check crashed.")
            return

        filtered = ssh_helper.filter_output(output, max_lines=80)
        if code == 0:
            logger.info("Automatic update check finished.\n%s", filtered)
        else:
            logger.error(
                "Automatic update check failed with exit code %d.\n%s", code, filtered
            )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(AutomationCog(bot))
