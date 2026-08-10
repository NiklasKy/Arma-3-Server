"""
Centralised configuration — reads all values from /app/.env at import time.
Every other module imports from here instead of reading os.environ directly.
"""

import os
from dotenv import load_dotenv

load_dotenv("/app/.env")


def _parse_ids(env_var: str, default: str = "") -> set[int]:
    """Parse a comma-separated list of IDs from an environment variable into a set of ints."""
    raw = os.getenv(env_var, default)
    if not raw:
        return set()
    try:
        return {int(v.strip()) for v in raw.split(",") if v.strip()}
    except ValueError as exc:
        raise ValueError(f"Invalid IDs in {env_var}='{raw}': {exc}") from exc


def _parse_bool(env_var: str, default: bool = False) -> bool:
    """Parse an explicit boolean environment value."""
    raw = os.getenv(env_var)
    if raw is None or not raw.strip():
        return default

    normalized = raw.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"Invalid boolean in {env_var}='{raw}'")


def _parse_bounded_int(env_var: str, default: int, minimum: int, maximum: int) -> int:
    """Parse an integer and reject values outside an operationally safe range."""
    raw = os.getenv(env_var, str(default)).strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"Invalid integer in {env_var}='{raw}'") from exc

    if not minimum <= value <= maximum:
        raise ValueError(
            f"{env_var} must be between {minimum} and {maximum}, got {value}"
        )
    return value


# ── Discord ────────────────────────────────────────────────────────────────────
DISCORD_TOKEN    = os.environ["DISCORD_BOT_TOKEN"]
GUILD_ID         = int(os.environ["DISCORD_GUILD_ID"])
# Comma-separated role IDs that are allowed to use bot commands
# e.g. DISCORD_ADMIN_ROLE_IDS=123456789,987654321
ADMIN_ROLE_IDS   = _parse_ids("DISCORD_ADMIN_ROLE_IDS")

# Optional: specific user IDs that bypass role checks
# e.g. DISCORD_ADMIN_USER_IDS=242292116833697792
ADMIN_USER_IDS   = _parse_ids("DISCORD_ADMIN_USER_IDS")

# ── SSH (container → Windows host) ────────────────────────────────────────────
SSH_HOST         = os.getenv("BOT_SSH_HOST", "host.docker.internal")
SSH_PORT         = int(os.getenv("BOT_SSH_PORT", "22"))
SSH_USER         = os.environ["BOT_SSH_USER"]
SSH_KEY_PATH     = os.getenv("BOT_SSH_KEY_PATH", "/app/ssh_key")

# Absolute path to the framework repo on the Windows host
# e.g. C:\#Arma Server\Framework\Arma-3-Server
SCRIPTS_PATH     = os.environ["BOT_SCRIPTS_PATH"]

# Host used by the bot container to reach the Arma 3 server query port (A2S)
SERVER_HOST      = os.getenv("BOT_SERVER_HOST", "host.docker.internal")

# Automatic maintenance. Disabled until explicitly enabled in .env.
AUTO_UPDATE_ENABLED = _parse_bool("BOT_AUTO_UPDATE_ENABLED", False)
AUTO_UPDATE_INTERVAL_MINUTES = _parse_bounded_int(
    "BOT_AUTO_UPDATE_INTERVAL_MINUTES", 60, 5, 10080
)
AUTO_UPDATE_INITIAL_DELAY_SECONDS = _parse_bounded_int(
    "BOT_AUTO_UPDATE_INITIAL_DELAY_SECONDS", 120, 0, 86400
)
AUTO_UPDATE_TIMEOUT_MINUTES = _parse_bounded_int(
    "BOT_AUTO_UPDATE_TIMEOUT_MINUTES", 180, 5, 1440
)

# ── Misc ───────────────────────────────────────────────────────────────────────
MAX_CHARS        = 1900   # Discord message limit is 2000; keep buffer for code-block markers
