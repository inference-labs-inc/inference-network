import subprocess
import sys
import os
import git
import time
import requests
from typing import Optional

from common.logging import get_logger

TARGET_BRANCH = "main"
REPO_URL = "https://github.com/inference-labs-inc/sertn-avs"
REQ_UPDATE_TIMEOUT = 60

logger = get_logger("auto_update")


def restart_app():
    """
    Restart the application to apply the updated changes
    """
    logger.info("App restarting due to auto-update")
    python = sys.executable
    # trunk-ignore(bandit/B606)
    os.execl(python, python, *sys.argv)


class AutoUpdate:
    """
    Automatic update utility
    """

    def __init__(self):
        self.last_check_time = 0
        try:
            self.repo = git.Repo(search_parent_directories=True)
        except Exception as e:
            logger.exception("Failed to initialize the repository")
            self.repo = None

    def get_local_latest_tag(self) -> Optional[git.Tag]:
        """
        Get the latest tag from the local git repository
        """
        try:
            tags = sorted(self.repo.tags, key=lambda t: t.commit.committed_datetime)
            current_tag: Optional[git.Tag] = tags[-1] if tags else None
            if current_tag:
                logger.info(f"Current tag: {current_tag.name}")
            return current_tag
        except Exception as e:
            logger.exception("Failed to get the current tag")
            return None

    def get_latest_release_tag(self):
        """
        Get the latest release tag from the GitHub repository
        """
        try:
            headers = {"Accept": "application/vnd.github.v3+json"}
            api_url = f"{REPO_URL.replace('github.com', 'api.github.com/repos')}/releases/latest"
            response = requests.get(api_url, headers=headers, timeout=10)
            response.raise_for_status()
            latest_release = response.json()
            return latest_release["tag_name"]
        except requests.RequestException as e:
            logger.exception("Failed to fetch the latest release from GitHub.")
            return None

    def attempt_packages_update(self):
        """
        Attempt to update the packages by installing the requirements from the requirements.txt file
        """
        logger.info("Attempting to update packages...")

        try:
            subprocess.check_call(
                [
                    "uv",
                    "sync",
                ],
                timeout=REQ_UPDATE_TIMEOUT,
            )
            logger.info("Successfully updated packages.")
        except Exception as e:
            logger.exception("Failed to update requirements")

    def update_to_latest_release(self) -> bool:
        """
        Update the repository to the latest release
        """
        try:

            if self.repo.is_dirty(untracked_files=False):
                logger.warning(
                    "Current changeset is dirty. Please commit changes, discard changes or update manually."
                )
                return False

            latest_release_tag_name = self.get_latest_release_tag()
            if not latest_release_tag_name:
                logger.error("Failed to fetch the latest release tag.")
                return False

            current_tag = self.get_local_latest_tag()

            if current_tag and current_tag.name == latest_release_tag_name:
                if self.repo.head.commit.hexsha == current_tag.commit.hexsha:
                    logger.info("Your version is up to date.")
                    return False
                logger.info(
                    "Latest release is checked out, however your commit is different."
                )
            else:
                logger.warning(
                    f"Attempting to check out the latest release: {latest_release_tag_name}..."
                )
                self.repo.remote().fetch(quiet=True, tags=True, force=True)
                if latest_release_tag_name not in [tag.name for tag in self.repo.tags]:
                    logger.error(
                        f"Latest release tag {latest_release_tag_name} not found in the repository."
                    )
                    return False

            self.repo.git.checkout(latest_release_tag_name)
            logger.info(
                f"Successfully checked out the latest release: {latest_release_tag_name}"
            )
            return True

        except Exception as e:
            logger.exception(
                "Automatic update failed. Manually pull the latest changes and update.",
            )

        return False

    def try_update(self):
        """
        Automatic update entrypoint method
        """
        if not self.repo:
            logger.warning("Git repository is not initialized.")
            return

        if time.time() - self.last_check_time < 300:
            return

        self.last_check_time = time.time()

        if not self.update_to_latest_release():
            return

        self.attempt_packages_update()

        logger.info("Restarting the application...")
        restart_app()
