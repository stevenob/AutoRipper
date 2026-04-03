from __future__ import annotations

from core.logger import get_logger, APP_NAME, VERSION
from gui.app import AutoRipperApp


def main():
    log = get_logger()
    log.info("%s %s starting", APP_NAME, VERSION)
    app = AutoRipperApp()
    app.mainloop()
    log.info("%s exiting", APP_NAME)


if __name__ == "__main__":
    main()
